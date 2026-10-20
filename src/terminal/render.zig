const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fastmem = @import("../fastmem.zig");
const lib = @import("lib.zig");
const color = @import("color.zig");
const cursor = @import("cursor.zig");
const highlight = @import("highlight.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const page = @import("page.zig");
const PageList = @import("PageList.zig");
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Style = @import("style.zig").Style;
const Terminal = @import("Terminal.zig");
const kitty_gfx = @import("kitty.zig").graphics;

const log = std.log.scoped(.render_state);

// Developer note: this is in src/terminal and not src/renderer because
// the goal is that this remains generic to multiple renderers. This can
// aid specifically with libghostty-vt with converting terminal state to
// a renderable form.

/// Contains the state required to render the screen, including optimizing
/// for repeated render calls and only rendering dirty regions.
///
/// Previously, our renderer would use `clone` to clone the screen within
/// the viewport to perform rendering. This worked well enough that we kept
/// it all the way up through the Ghostty 1.2.x series, but the clone time
/// was repeatedly a bottleneck blocking IO.
///
/// Rather than a generic clone that tries to clone all screen state per call
/// (within a region), a stateful approach that optimizes for only what a
/// renderer needs to do makes more sense.
///
/// To use this, initialize the render state to empty, then call `update`
/// on each frame to update the state to the latest terminal state.
///
///     var state: RenderState = .empty;
///     defer state.deinit(alloc);
///     state.update(alloc, &terminal);
///
/// ## Two-Phase Updates
///
/// For callers that synchronize terminal access (e.g. a renderer thread
/// sharing a lock with an IO thread), the update can be split into two
/// phases to minimize the time the terminal must be held exclusively:
/// `beginUpdate` requires terminal access, while `endUpdate` completes
/// any deferred work using only memory owned by the render state.
///
///     {
///         mutex.lock();
///         defer mutex.unlock();
///         try state.beginUpdate(alloc, &terminal);
///     }
///
///     // The IO thread is free to modify the terminal while we
///     // complete the update.
///     state.endUpdate();
///
/// The render state must be treated as incomplete between the two calls.
/// `update` is a convenience that performs both phases in one call.
///
/// ## Overscan
///
/// By default the render state captures exactly the rows of the viewport.
/// A renderer that draws the grid at a fractional row offset, such as for
/// smooth scrolling, also needs the rows just outside the viewport so that
/// partially visible rows at the top and bottom edges can be drawn. Set
/// `overscan_request` to ask for extra rows above and below the viewport:
///
///     var state: RenderState = .empty;
///     defer state.deinit(alloc);
///     state.overscan_request = .{ .above = 1, .below = 1 };
///     try state.update(alloc, &terminal);
///
/// With overscan, `row_data` holds more than `rows` entries, laid out
/// like this for a request of one row above and one below:
///
///     index 0            overscan above   (viewport y = -1)
///     index 1            viewport row 0   <- viewportStart()
///     ...
///     index rows         viewport row rows - 1
///     index rows + 1     overscan below   (viewport y = rows)
///
/// The viewport always begins at `viewportStart()`, so viewport rows never
/// move within `row_data` from one update to the next. The overscan rows
/// are only captured if they exist. There is nothing above the first row
/// of scrollback, and nothing below the viewport while it follows the
/// active area (the usual case when not scrolled). Missing rows leave
/// their entries unused, and `overscan` reports how many rows were
/// actually captured. Always read rows through `rowDataRange()`:
///
///     const range = state.rowDataRange();
///     const rows = state.row_data.slice();
///     for (range.start..range.end) |i| {
///         const y = state.viewportY(i); // negative above the viewport
///         const cells = rows.items(.cells)[i];
///         // draw `cells` at row `y` shifted by the scroll offset
///     }
///
/// Overscan rows carry the same data as viewport rows (cells, styles,
/// dirty flags, selection, and highlights). The cursor is only reported
/// in `cursor.viewport` when it is inside the viewport itself. `string`
/// and `linkCells` only look at the viewport.
///
/// With no overscan requested (the default), `row_data` holds exactly
/// the viewport and indices are viewport y values, as before.
///
/// ## Images
///
/// The render state also gives the images to draw, as a list of image
/// placements (`ImagePlacement`). Each one is a rectangle of one image,
/// with its position, size, source rectangle and draw order. These mean
/// the same thing for every image protocol, so a renderer can draw them
/// all the same way. Only reading the pixels depends on the protocol:
///
///     var it = state.imagePlacementIterator();
///     while (it.next()) |p| {
///         // `kittyTexture` and `queue` stand in for your renderer.
///         // Find or upload a texture keyed by the protocol, image ID
///         // and image generation. Only read pixels on a miss.
///         const texture = switch (p.protocol) {
///             .kitty => kittyTexture(p.image_id, p.image_generation),
///         };
///
///         // Draw p.source_* of the texture at cell (p.x, p.y), offset
///         // by (p.offset_x, p.offset_y) pixels, at a size of p.width by
///         // p.height pixels, sorted by p.layer and then p.z.
///         queue(texture, p);
///     }
///
/// Currently the list holds the Kitty graphics images shown with
/// placeholder cells (see below). Kitty images at a fixed position on
/// screen are not included yet. Read those from the terminal's image
/// storage.
///
/// ### Kitty Graphics Placeholders
///
/// The Kitty graphics protocol lets a program place an image with text.
/// The program creates a virtual placement, which has no position of its
/// own, and prints placeholder characters (U+10EEEE) where the image
/// should appear. Each placeholder cell says which image it shows and
/// which piece of the image belongs in that cell. The image then moves
/// with the text.
///
/// Because the cells decide where these images go, the render state
/// works out where to draw them during each update:
///
///   1. When a row is rebuilt, its placeholder cells are grouped into
///      runs of neighboring cells that show the same image. These are
///      stored in `Row.placeholders`.
///   2. `beginUpdate` then looks up each new run's image and placement
///      and calculates the part of the image it shows, and where. Runs
///      on rows that didn't change keep their results, unless the
///      images or the cell size changed.
///   3. Relative placements attached to a virtual placement are
///      positioned from that placement's runs.
///
/// ## Memory
///
/// Note: the render state retains as much memory as possible between updates
/// to prevent future allocations. If a very large frame is rendered once,
/// the render state will retain that much memory until deinit. To avoid
/// waste, it is recommended that the caller `deinit` and start with an
/// empty render state every so often.
pub const RenderState = struct {
    /// The current screen dimensions. It is possible that these don't match
    /// the renderer's current dimensions in grid cells because resizing
    /// can happen asynchronously. For example, for Metal, our NSView resizes
    /// at a different time than when our internal terminal state resizes.
    /// This can lead to a one or two frame mismatch a renderer needs to
    /// handle.
    ///
    /// The viewport is always exactly equal to the active area size so this
    /// is also the viewport size. It does not include overscan rows.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    /// The color state for the terminal.
    colors: Colors,

    /// Cursor state within the viewport.
    cursor: Cursor,

    /// The captured rows, from top to bottom.
    ///
    /// Without overscan this has exactly `rows` entries and the index is
    /// the viewport y. With overscan it has room for the requested rows
    /// above and below the viewport, and the viewport starts at
    /// `viewportStart()`. Only the entries in `rowDataRange()` hold data
    /// from the last update. See "Overscan" in the `RenderState` docs.
    ///
    /// This is a MultiArrayList because only the update cares about
    /// the allocators. Callers care about all the other properties, and
    /// this better optimizes cache locality for read access for those
    /// use cases.
    row_data: std.MultiArrayList(Row),

    /// The dirty state of the render state. This is set by the update method.
    /// The renderer/caller should set this to false when it has handled
    /// the dirty state.
    dirty: Dirty,

    /// The screen type that this state represents. This is used primarily
    /// to detect changes.
    screen: ScreenSet.Key,

    /// The last viewport pin used to generate this state. This is NOT
    /// a tracked pin and is generally NOT safe to read other than the direct
    /// values for comparison.
    viewport_pin: ?PageList.Pin = null,

    /// The number of rows to capture above and below the viewport. This is
    /// for renderers that draw partially visible rows, such as during
    /// smooth scrolling. The default of zero captures only the viewport.
    /// See "Overscan" in the `RenderState` docs.
    ///
    /// Only change this immediately before an update, because
    /// `viewportStart()` reads it and `row_data` is laid out for it by the
    /// update. Changing it causes the next update to be a full redraw.
    overscan_request: Overscan = .{},

    /// The number of rows above and below the viewport that the last
    /// update actually captured. This is never more than
    /// `overscan_request`, and is less when those rows don't exist:
    ///
    ///   - `above` is less near the top of the scrollback.
    ///   - `below` is less when the viewport is close to the bottom of
    ///     the screen, and is zero when the viewport follows the active
    ///     area.
    ///
    /// This is set by the update and should not be modified.
    overscan: Overscan = .{},

    /// The cached selection so we can avoid expensive selection calculations
    /// if possible.
    selection_cache: ?SelectionCache = null,

    /// The pending style runs requiring an endUpdate call, in the
    /// order they were recorded. If multiple begins happen without an
    /// endUpdate call, runs accumulate; rows rebuilt more than once
    /// may then have superseded (stale) runs in this list, which is
    /// harmless: newer runs are appended later so they win, and cells
    /// not covered by newer runs have a default style ID in their raw
    /// data so their style is undefined by contract anyway. See
    /// beginUpdate.
    pending_styles: std.ArrayList(StyleRun) = .empty,

    /// Internal state for Kitty graphics placeholders. Read the results
    /// with `imagePlacementIterator` instead.
    kitty: Kitty.Data = .{},

    /// Initial state.
    pub const empty: RenderState = .{
        .rows = 0,
        .cols = 0,
        .colors = .{
            .background = .{ .r = 0, .g = 0, .b = 0 },
            .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
            .cursor = null,
            .palette = color.default,
        },
        .cursor = .{
            .active = .{ .x = 0, .y = 0 },
            .viewport = null,
            .cell = .{},
            .style = undefined,
            .visual_style = .block,
            .password_input = false,
            .visible = true,
            .blinking = false,
        },
        .row_data = .empty,
        .dirty = .false,
        .screen = .primary,
    };

    /// The color state for the terminal.
    ///
    /// The background/foreground will be reversed if the terminal reverse
    /// color mode is on! You do not need to handle that manually!
    pub const Colors = struct {
        background: color.RGB,
        foreground: color.RGB,
        cursor: ?color.RGB,
        palette: color.Palette,
    };

    pub const Cursor = struct {
        /// The x/y position of the cursor within the active area.
        active: point.Coordinate,

        /// The x/y position of the cursor within the viewport. This
        /// may be null if the cursor is not visible within the viewport.
        viewport: ?Viewport,

        /// The cell data for the cursor position. Managed memory is not
        /// safe to access from this.
        cell: page.Cell,

        /// The style, always valid even if the cell is default style.
        style: Style,

        /// The visual style of the cursor itself, such as a block or
        /// bar.
        visual_style: cursor.Style,

        /// True if the cursor is detected to be at a password input field.
        password_input: bool,

        /// Cursor visibility state determined by the terminal mode.
        visible: bool,

        /// Cursor blink state determined by the terminal mode.
        blinking: bool,

        pub const Viewport = struct {
            /// The x/y position of the cursor within the viewport.
            x: size.CellCountInt,
            y: size.CellCountInt,

            /// Whether the cursor is part of a wide character and
            /// on the tail of it. If so, some renderers may use this
            /// to move the cursor back one.
            wide_tail: bool,
        };
    };

    /// A number of rows above and below the viewport. Used both to request
    /// overscan (`overscan_request`) and to report what was captured
    /// (`overscan`).
    pub const Overscan = struct {
        /// Rows above the top of the viewport.
        above: size.CellCountInt = 0,

        /// Rows below the bottom of the viewport.
        below: size.CellCountInt = 0,

        pub fn eql(a: Overscan, b: Overscan) bool {
            return a.above == b.above and a.below == b.below;
        }
    };

    /// A captured row. This is either a viewport row or an overscan row,
    /// depending on its index in `row_data`.
    pub const Row = struct {
        /// Arena used for any heap allocations for cell contents
        /// in this row. Importantly, this is NOT used for the MultiArrayList
        /// itself. We do this on purpose so that we can easily clear rows,
        /// but retain cached MultiArrayList capacities since grid sizes don't
        /// change often.
        arena: ArenaAllocator.State,

        /// The page pin. Its copied values may be compared, but its node must
        /// not be dereferenced unless the terminal state is protected from
        /// changes since the last `update` call.
        pin: PageList.Pin,

        /// The page node generation captured alongside `pin`. This lets
        /// consumers validate the pin without dereferencing its node after
        /// the terminal lock has been released.
        serial: u64,

        /// Raw row data.
        raw: page.Row,

        /// The cells in this row. Guaranteed to be `cols` length.
        cells: std.MultiArrayList(Cell),

        /// A dirty flag that can be used by the renderer to track
        /// its own draw state. `update` will mark this true whenever
        /// this row is changed, too.
        dirty: bool,

        /// The x range of the selection within this row.
        selection: ?[2]size.CellCountInt,

        /// The highlights within this row.
        highlights: std.ArrayList(Highlight),

        /// The runs of Kitty graphics placeholder cells in this row, from
        /// left to right. Most callers want `imagePlacementIterator`,
        /// which reads these for every row. This is always empty when
        /// Kitty graphics are disabled.
        ///
        /// This uses the row arena, like highlights.
        placeholders: std.ArrayList(Placeholder),

        /// The style runs applied to this row's per-cell style data
        /// by the last `endUpdate` that touched it. This is what lets
        /// `endUpdate` skip the (comparatively large) per-cell style
        /// fill when a rebuilt row produced identical runs, which is
        /// the common case: text changes far more often than styling.
        ///
        /// The invariant is that this always describes the current
        /// contents of the cell style data for the covered ranges. It
        /// is cleared whenever the cell storage is reallocated.
        ///
        /// This uses the general allocator (NOT the row arena)
        /// because it must survive row rebuilds. `endUpdate` cannot
        /// allocate, so `beginUpdate` reserves the capacity.
        applied_styles: std.ArrayList(StyleRun),

        /// Identifies a row of terminal content across updates, independent
        /// of where the row is in `row_data`. Get it with `id`.
        ///
        /// When the viewport scrolls, rows move to different `row_data`
        /// indices but keep their ids. This lets a renderer keep per-row
        /// work (such as shaped text or cached geometry) and look it up by
        /// id after each update rather than rebuilding everything:
        ///
        ///     const range = state.rowDataRange();
        ///     for (range.start..range.end) |i| {
        ///         const row = state.row_data.get(i);
        ///         if (!row.dirty) {
        ///             if (cache.get(row.id())) |cached| {
        ///                 // reuse `cached` at the new position
        ///                 continue;
        ///             }
        ///         }
        ///         // rebuild this row and cache it under row.id()
        ///     }
        ///
        /// The guarantee is: if a row has the same id as a row from the
        /// previous update of the same render state and is not marked dirty,
        /// its contents are unchanged. An id that no longer appears means
        /// the row scrolled out of the captured rows, was removed from
        /// scrollback, or was rearranged in place by the terminal (for
        /// example, scrolling within a scroll region). Ids are never reused,
        /// so a stale id never matches a different row.
        pub const Id = struct {
            /// The generation of the page holding the row
            /// (`PageList.List.Node.serial`).
            serial: u64,

            /// The row index within its page.
            y: size.CellCountInt,

            pub fn eql(a: Id, b: Id) bool {
                return a.serial == b.serial and a.y == b.y;
            }
        };

        /// Returns the identity of this row. See `Id`.
        ///
        /// This only reads values copied during the update, so it is safe
        /// to call without access to the terminal.
        pub fn id(self: *const Row) Id {
            return .{ .serial = self.serial, .y = self.pin.y };
        }
    };

    pub const Highlight = struct {
        /// A special tag that can be used by the caller to differentiate
        /// different highlight types. The value is opaque to the RenderState.
        tag: u8,

        /// The x ranges of highlights within this row.
        range: [2]size.CellCountInt,
    };

    /// A run of neighboring Kitty graphics placeholder cells in one row.
    /// See `Row.placeholders`.
    pub const Placeholder = Kitty.Placeholder;

    /// The image protocols that a render state can find image placements
    /// for. See `ImagePlacement.protocol`.
    pub const ImageProtocol = lib.Enum(lib.target, &.{
        // The Kitty graphics protocol.
        "kitty",
    });

    /// Where an image is drawn relative to the text of the terminal.
    ///
    /// Draw in this order: images below backgrounds, then cell
    /// backgrounds, then images below text, then text, then images above
    /// text. Within a layer, draw images in order of their z-index,
    /// lowest first.
    pub const ImageLayer = lib.Enum(lib.target, &.{
        // Below the cell background colors.
        "below_background",

        // Above the cell background colors and below the text.
        "below_text",

        // Above the text.
        "above_text",
    });

    /// One rectangle of an image to draw. See `imagePlacementIterator`.
    ///
    /// To draw it, take the `source_*` rectangle of the image and draw
    /// it `width` by `height` pixels in size, at this position:
    ///
    ///     px_x = x * cell_width + offset_x
    ///     px_y = y * cell_height + offset_y
    ///
    /// where (px_x, px_y) is relative to the top-left of the viewport.
    /// Get the image's pixels from the storage of its `protocol`, using
    /// `image_id`.
    pub const ImagePlacement = struct {
        /// The protocol the image came from, and the information that
        /// only applies to that protocol.
        protocol: Protocol,

        /// The ID of the image to draw. IDs are only unique within one
        /// protocol, so always look the image up in the storage of
        /// `protocol`.
        image_id: u32,

        /// The generation of the image's contents when the placement was
        /// found. It changes whenever the image's pixels change, so it
        /// works as a cache key for textures: if it matches the texture
        /// you already have for this protocol and image ID, you don't
        /// need to read the pixels again.
        image_generation: u64,

        /// The layer to draw the image in, and the z-index that orders
        /// images within the layer. Lower z-indexes are drawn first.
        layer: ImageLayer,
        z: i32,

        /// The top-left cell, where (0, 0) is the top-left cell of the
        /// viewport. `y` is negative for overscan rows above the
        /// viewport, like `viewportY`. Some placements can also start
        /// above or to the left of the viewport.
        x: i32,
        y: i32,

        /// The number of columns and rows of cells covered, starting at
        /// `x` and `y`.
        cols: u32,
        rows: u32,

        /// Where the image starts within the top-left cell, in pixels.
        /// An image that doesn't fill its cells is centered, so these
        /// can be larger than one cell.
        offset_x: u32,
        offset_y: u32,

        /// The size to draw the image at, in pixels.
        width: u32,
        height: u32,

        /// The part of the image to draw, in image pixels.
        source_x: u32,
        source_y: u32,
        source_width: u32,
        source_height: u32,

        pub const Protocol = union(ImageProtocol) {
            kitty: KittyPlacement,
        };
    };

    /// Information that only applies to Kitty graphics placements. See
    /// `ImagePlacement.protocol`.
    pub const KittyPlacement = Kitty.Placement;

    /// Iterates over the image placements found by the last update. Get
    /// one with `imagePlacementIterator`.
    ///
    /// The order is not the order to draw in. Sort by layer and then
    /// z-index before drawing. Only placements with something to draw
    /// are returned.
    pub const ImagePlacementIterator = struct {
        rows: []const std.ArrayList(Placeholder),
        viewport_y_base: isize,
        relative: []const ImagePlacement,
        y: usize = 0,
        i: usize = 0,

        pub fn next(self: *ImagePlacementIterator) ?ImagePlacement {
            while (self.y < self.rows.len) {
                const runs = self.rows[self.y].items;
                while (self.i < runs.len) {
                    const run = &runs[self.i];
                    self.i += 1;
                    if (run.state != .visible) continue;
                    const g = run.geometry;
                    return .{
                        .protocol = .{ .kitty = .{
                            .kind = .virtual,
                            .placement_id = run.placement_id,
                        } },
                        .image_id = run.image_id,
                        .image_generation = g.image_generation,
                        .layer = .below_text,
                        .z = -1,
                        .x = run.x,
                        .y = @intCast(self.viewport_y_base + @as(isize, @intCast(self.y))),
                        .cols = run.width,
                        .rows = 1,
                        .offset_x = g.offset_x,
                        .offset_y = g.offset_y,
                        .width = g.width,
                        .height = g.height,
                        .source_x = g.source_x,
                        .source_y = g.source_y,
                        .source_width = g.source_width,
                        .source_height = g.source_height,
                    };
                }
                self.y += 1;
                self.i = 0;
            }

            const idx = self.i;
            if (idx >= self.relative.len) return null;
            self.i += 1;
            return self.relative[idx];
        }
    };

    /// Returns an iterator over the image placements that the last update
    /// found. This covers every captured row, including overscan rows.
    ///
    /// Currently these are the Kitty graphics placements shown through
    /// placeholder cells (see "Kitty Graphics Placeholders" in the
    /// `RenderState` docs). Images at a fixed position on screen are not
    /// included yet. Read those from the terminal's image storage.
    ///
    /// This only reads memory owned by the render state, so it doesn't
    /// need access to the terminal. The next update invalidates the
    /// iterator.
    pub fn imagePlacementIterator(self: *const RenderState) ImagePlacementIterator {
        const range = self.rowDataRange();
        return .{
            .rows = self.row_data.items(.placeholders)[range.start..range.end],
            .viewport_y_base = self.viewportY(range.start),
            .relative = self.kitty.relative.items,
        };
    }

    pub const Cell = struct {
        /// Always set, this is the raw copied cell data from page.Cell.
        /// The managed memory (hyperlinks, graphames, etc.) is NOT safe
        /// to access from here. It is duplicated into the other fields if
        /// it exists.
        raw: page.Cell,

        /// Grapheme data for the cell. This is undefined unless the
        /// raw cell's content_tag is `codepoint_grapheme`.
        grapheme: []const u21,

        /// The style data for the cell. This is undefined unless
        /// the style_id is non-default on raw.
        style: Style,
    };

    // Dirty state.
    pub const Dirty = lib.Enum(lib.target, &.{
        // Not dirty at all. Can skip rendering if prior state was
        // already rendered.
        "false",

        // Some rows changed but not all. None of the global state
        // changed such as colors.
        "partial",

        // Global state changed or dimensions changed. All rows should
        // be redrawn.
        "full",
    });

    const SelectionCache = struct {
        selection: Selection,
        tl_pin: PageList.Pin,
        br_pin: PageList.Pin,
    };

    /// A run of cells within one row sharing one style, pending
    /// denormalization into the per-cell data. This is populated by
    /// `beginUpdate` and consumed by `endUpdate`. This exists so that
    /// the (potentially large) denormalization of styles into cells
    /// can happen outside of any terminal locks. See `beginUpdate`.
    pub const StyleRun = struct {
        /// The `row_data` index of the row.
        y: size.CellCountInt,

        /// Start (inclusive) and end (exclusive) x coordinates.
        start: size.CellCountInt,
        end: size.CellCountInt,

        /// The style for this cell range.
        style: Style,
    };

    pub fn deinit(self: *RenderState, alloc: Allocator) void {
        for (
            self.row_data.items(.arena),
            self.row_data.items(.cells),
            self.row_data.items(.applied_styles),
        ) |state, *cells, *applied| {
            var arena: ArenaAllocator = state.promote(alloc);
            arena.deinit();
            cells.deinit(alloc);
            applied.deinit(alloc);
        }
        self.row_data.deinit(alloc);
        self.pending_styles.deinit(alloc);
        self.kitty.deinit(alloc);
    }

    /// Update the render state to the latest terminal state.
    ///
    /// This is a convenience function that performs a full update in
    /// one call, equivalent to `beginUpdate` immediately followed by
    /// `endUpdate`. Callers that hold a lock over the terminal state
    /// should prefer calling the two phases directly so that the lock
    /// is only held for `beginUpdate`.
    ///
    /// This will reset the terminal dirty state since it is consumed
    /// by this render state update.
    pub fn update(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        try self.beginUpdate(alloc, t);
        self.endUpdate();
    }

    /// Begin an update of the render state to the latest terminal
    /// state. Every begin must be completed with an `endUpdate` call
    /// before the render state is read.
    ///
    /// This two-phase structure exists for callers that lock the
    /// terminal state: only this function requires terminal access, so
    /// a caller can hold its lock for this call only and then call
    /// `endUpdate` after releasing it. `endUpdate` exclusively reads
    /// and writes memory owned by the render state.
    ///
    /// Work that doesn't require terminal access may be deferred to
    /// `endUpdate` to keep this call (and therefore lock hold time) as
    /// short as possible. At the time of writing, the deferred work is
    /// the per-cell style denormalization, so between this call and
    /// `endUpdate` the per-cell `style` data of any updated rows is
    /// stale and must not be read. More work may be deferred in the
    /// future; callers should treat the render state as incomplete
    /// until `endUpdate` is called.
    ///
    /// This will reset the terminal dirty state since it is consumed
    /// by this render state update.
    pub fn beginUpdate(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        const s: *Screen = t.screens.active;
        const viewport_pin = s.pages.getTopLeft(.viewport);

        // The overscan rows to capture beyond the viewport. The request
        // decides the layout of row_data, and the actual counts are
        // limited to the rows that exist. With no request, everything
        // below behaves exactly as it does without overscan.
        const above_req: usize = self.overscan_request.above;
        const below_req: usize = self.overscan_request.below;
        const row_data_len: usize = above_req + s.pages.rows + below_req;

        // The first captured row and how many rows above the viewport
        // we actually got.
        const top: struct { pin: PageList.Pin, above: usize } = if (above_req == 0)
            .{ .pin = viewport_pin, .above = 0 }
        else switch (viewport_pin.upOverflow(above_req)) {
            .offset => |p| .{ .pin = p, .above = above_req },
            .overflow => |o| .{ .pin = o.end, .above = above_req - o.remaining },
        };

        // How many rows below the viewport we actually get. The page list
        // ends at the last active row, so this is zero whenever the
        // viewport follows the active area. This is computed before the
        // loop below so that a change can force a redraw. When new output
        // appears below a scrolled viewport, it can land in an entry that
        // was never built or that held a different row.
        const below: usize = if (below_req == 0) 0 else below: {
            const bottom = viewport_pin.down(s.pages.rows - 1).?;
            break :below switch (bottom.downOverflow(below_req)) {
                .offset => below_req,
                .overflow => |o| below_req - o.remaining,
            };
        };

        // The index of top.pin in row_data.
        const first: usize = above_req - top.above;

        const redraw = redraw: {
            // If our screen key changed, we need to do a full rebuild
            // because our render state is viewport-specific.
            if (t.screens.active_key != self.screen) break :redraw true;

            // If our terminal is dirty at all, we do a full rebuild. These
            // dirty values are full-terminal dirty values.
            {
                const Int = @typeInfo(Terminal.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.flags.dirty);
                if (v > 0) break :redraw true;
            }

            // If our screen is dirty at all, we do a full rebuild. This is
            // a full screen dirty tracker.
            {
                const Int = @typeInfo(Screen.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.screens.active.dirty);
                if (v > 0) break :redraw true;
            }

            // If our dimensions changed, we do a full rebuild.
            if (self.rows != s.pages.rows or
                self.cols != s.pages.cols)
            {
                break :redraw true;
            }

            // If our row_data layout changed (overscan request changed),
            // we do a full rebuild.
            if (self.row_data.len != row_data_len) break :redraw true;

            // If the captured overscan changed, rows may have entered
            // row_data that were never built. This only happens when the
            // viewport is scrolled, so it's cheap to be safe.
            if (self.overscan.above != top.above or
                self.overscan.below != below) break :redraw true;

            // If our viewport pin changed, we do a full rebuild.
            if (self.viewport_pin) |old| {
                if (!old.eql(viewport_pin)) break :redraw true;
            }

            break :redraw false;
        };

        // Always set our cheap fields, its more expensive to compare
        self.rows = s.pages.rows;
        self.cols = s.pages.cols;
        self.viewport_pin = viewport_pin;
        self.cursor.active = .{ .x = s.cursor.x, .y = s.cursor.y };
        self.cursor.cell = s.cursor.page_cell.*;
        self.cursor.style = s.cursor.style;
        self.cursor.visual_style = s.cursor.cursor_style;
        self.cursor.password_input = t.flags.password_input;
        self.cursor.visible = t.modes.get(.cursor_visible);
        self.cursor.blinking = t.modes.get(.cursor_blinking);

        // Always reset the cursor viewport position. In the future we can
        // probably cache this by comparing the cursor pin and viewport pin
        // but may not be worth it.
        self.cursor.viewport = null;

        // Colors.
        self.colors.cursor = t.colors.cursor.get();

        // The palette is a relatively large copy (768 bytes at the time
        // of writing) so we only copy it when it could have changed. All
        // palette modifications set a terminal-level dirty flag (see
        // Terminal.Dirty.palette), and any terminal-level dirty flag
        // forces a redraw, so checking redraw is sufficient.
        if (redraw) self.colors.palette = t.colors.palette.current;

        bg_fg: {
            // Background/foreground can be unset initially which would
            // depend on "default" background/foreground. The expected use
            // case of Terminal is that the caller set their own configured
            // defaults on load so this doesn't happen.
            const bg = t.colors.background.get() orelse break :bg_fg;
            const fg = t.colors.foreground.get() orelse break :bg_fg;
            if (t.modes.get(.reverse_colors)) {
                self.colors.background = fg;
                self.colors.foreground = bg;
            } else {
                self.colors.background = bg;
                self.colors.foreground = fg;
            }
        }

        // Ensure our row length is exactly our height plus requested
        // overscan, freeing or allocating data as necessary. In
        // most cases we'll have a perfectly matching size.
        if (self.row_data.len != row_data_len) {
            @branchHint(.unlikely);

            if (self.row_data.len < row_data_len) {
                // Resize our rows to the desired length, marking any added
                // values undefined.
                const old_len = self.row_data.len;
                try self.row_data.resize(alloc, row_data_len);

                // Initialize all our values. Its faster to use slice() + set()
                // because appendAssumeCapacity does this multiple times.
                var row_data = self.row_data.slice();
                for (old_len..row_data_len) |y| {
                    row_data.set(y, .{
                        .arena = .{},
                        .pin = undefined,
                        .serial = undefined,
                        .raw = undefined,
                        .cells = .empty,
                        .dirty = true,
                        .selection = null,
                        .highlights = .empty,
                        .placeholders = .empty,
                        .applied_styles = .empty,
                    });
                }
            } else {
                const row_data = self.row_data.slice();
                for (
                    row_data.items(.arena)[row_data_len..],
                    row_data.items(.cells)[row_data_len..],
                    row_data.items(.applied_styles)[row_data_len..],
                ) |state, *cell, *applied| {
                    var arena: ArenaAllocator = state.promote(alloc);
                    arena.deinit();
                    cell.deinit(alloc);
                    applied.deinit(alloc);
                }
                self.row_data.shrinkRetainingCapacity(row_data_len);
            }
        }

        // Break down our row data
        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_pins = row_data.items(.pin);
        const row_serials = row_data.items(.serial);
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_sels = row_data.items(.selection);
        const row_highlights = row_data.items(.highlights);
        const row_placeholders = row_data.items(.placeholders);
        const row_dirties = row_data.items(.dirty);
        const row_applied = row_data.items(.applied_styles);

        // If we're redrawing then every row will be rebuilt, superseding
        // any pending style runs from prior updates. Clearing also
        // guarantees pending runs always match the current dimensions
        // (dimension changes force a redraw).
        if (redraw) self.pending_styles.clearRetainingCapacity();

        // Go through and setup our rows. We iterate page chunks rather
        // than individual rows so that per-page work (dirty flags, cursor
        // detection, memory pointers) is hoisted out of the row loop. This
        // makes the common case of a clean (or mostly clean) frame very
        // cheap: a contiguous scan of row dirty flags.
        const builder: RowBuilder = .{
            .alloc = alloc,
            .cols = self.cols,
            .arenas = row_arenas,
            .raws = row_rows,
            .cells = row_cells,
            .sels = row_sels,
            .highlights = row_highlights,
            .placeholders = row_placeholders,
            .kitty_stale = &self.kitty.stale,
            .dirties = row_dirties,
            .pending_styles = &self.pending_styles,
            .applied_styles = row_applied,
        };
        const row_data_end: usize = first + top.above + self.rows + below;
        var y: usize = first;
        var any_dirty: bool = false;
        var page_it = top.pin.pageIterator(.right_down, null);
        while (y < row_data_end) {
            const chunk = page_it.next() orelse break;
            const node = chunk.node;
            const node_serial = node.serial;
            const p: *page.Page = node.page();

            // The number of rows we consume from this chunk. The chunk
            // may extend beyond what we capture (the viewport is always
            // exactly `rows` tall, plus any overscan) so we clamp.
            const take: usize = @min(
                @as(usize, chunk.end - chunk.start),
                row_data_end - y,
            );

            // Find our cursor if we haven't found it yet. We do this even
            // if rows are not dirty because the cursor is unrelated. We
            // can check the chunk bounds once rather than every row.
            if (self.cursor.viewport == null and
                node == s.cursor.page_pin.node)
            cursor: {
                const cy = s.cursor.page_pin.y;
                if (cy < chunk.start or cy >= chunk.start + take) break :cursor;

                // The cursor may be in an overscan row, in which case it
                // is not visible in the viewport.
                const idx = y + (cy - chunk.start);
                const vp_start = self.viewportStart();
                if (idx < vp_start or idx >= vp_start + self.rows) break :cursor;
                self.cursor.viewport = .{
                    .y = @intCast(idx - vp_start),
                    .x = s.cursor.x,

                    // Future: we should use our own state here to look this
                    // up rather than calling this.
                    .wide_tail = if (s.cursor.x > 0)
                        s.cursorCellLeft(1).wide == .wide
                    else
                        false,
                };
            }

            // The page-level dirty flag applies to every row in the chunk.
            // We consume (clear) it now; each node appears at most once in
            // this iteration and we're the only consumer of dirty state.
            const page_dirty = p.dirty;
            if (page_dirty) p.dirty = false;

            // Get our contiguous rows for this chunk.
            const page_rows: []page.Row = p.rows.ptr(p.memory)[chunk.start..][0..take];
            assert(p.size.cols == self.cols);

            // Store our pins and their node generations. We have to store
            // these even for rows that aren't dirty because dirty is only a
            // renderer optimization; it doesn't apply to memory movement.
            // This lets us remap any cell pins back to an exact entry in our
            // RenderState and validate them later without dereferencing a
            // potentially stale node.
            //
            // We can skip the writes when the pins and serials are unchanged:
            // if we're not redrawing, every value was stored by a prior update
            // (row count changes force a redraw). Within a single update a
            // node appears at most once and its stored pins have consecutive
            // y values, so if the first and last entries of this chunk's range
            // already match then every entry in between matches too.
            if (redraw or
                row_pins[y].node != node or
                row_pins[y].y != chunk.start or
                row_serials[y] != node_serial or
                row_pins[y + take - 1].node != node or
                row_pins[y + take - 1].y != chunk.start + take - 1 or
                row_serials[y + take - 1] != node_serial)
            {
                for (
                    row_pins[y..][0..take],
                    row_serials[y..][0..take],
                    chunk.start..,
                ) |*pin, *serial, py| {
                    pin.* = .{ .node = node, .y = @intCast(py) };
                    serial.* = node_serial;
                }
            }

            if (!redraw and !page_dirty) {
                // Only dirty rows (usually none) need a rebuild. Scan the
                // dirty flags a group at a time; the dirty bit is directly
                // testable on the packed row representation.
                var i: usize = 0;
                while (take - i >= RowDirtyMask.group_len) : (i += RowDirtyMask.group_len) {
                    if (RowDirtyMask.match(page_rows, i)) {
                        @branchHint(.likely);
                        continue;
                    }

                    for (page_rows[i..][0..RowDirtyMask.group_len], i..) |*page_row, j| {
                        if (!page_row.dirty) continue;
                        page_row.dirty = false;
                        any_dirty = true;
                        try builder.row(p, page_row, y + j);
                    }
                }
                while (i < take) : (i += 1) {
                    const page_row = &page_rows[i];
                    if (!page_row.dirty) continue;
                    page_row.dirty = false;
                    any_dirty = true;
                    try builder.row(p, page_row, y + i);
                }
            } else {
                // Rebuild every row in the chunk.
                any_dirty = true;
                for (page_rows, 0..) |*page_row, i| {
                    page_row.dirty = false;
                    try builder.row(p, page_row, y + i);
                }
            }

            y += take;
        }
        assert(y == row_data_end);

        self.overscan = .{
            .above = @intCast(top.above),
            .below = @intCast(below),
        };

        // Work out what the Kitty placeholder runs draw. This must come
        // after setting the overscan above, because it reads the
        // captured rows.
        if (comptime build_options.kitty_graphics) try Kitty.update(
            self,
            alloc,
            t,
            redraw,
            any_dirty,
        );

        // If our screen has a selection, then mark the rows with the
        // selection. We do this outside of the loop above because its unlikely
        // a selection exists and because the way our selections are structured
        // today is very inefficient.
        //
        // NOTE: To improve the performance of the block below, we'll need
        // to rethink how we model selections in general.
        //
        // There are performance improvements that can be made here, though.
        // For example, `containedRow` recalculates a bunch of information
        // we can cache.
        if (s.selection) |*sel| selection: {
            @branchHint(.unlikely);

            // Populate our selection cache to avoid some expensive
            // recalculation.
            const cache: *const SelectionCache = cache: {
                if (self.selection_cache) |*c| cache_check: {
                    // If we're redrawing, we recalculate the cache just to
                    // be safe.
                    if (redraw) break :cache_check;

                    // If our selection isn't equal, we aren't cached!
                    if (!c.selection.eql(sel.*)) break :cache_check;

                    // If we have no dirty rows, we can not recalculate.
                    if (!any_dirty) break :selection;

                    // We have dirty rows, we can utilize the cache.
                    break :cache c;
                }

                // Create a new cache
                const tl_pin = sel.topLeft(s);
                const br_pin = sel.bottomRight(s);
                self.selection_cache = .{
                    .selection = .init(tl_pin, br_pin, sel.rectangle),
                    .tl_pin = tl_pin,
                    .br_pin = br_pin,
                };
                break :cache &self.selection_cache.?;
            };

            // Grab the inefficient data we need from the selection. At
            // least we can cache it.
            const tl = s.pages.pointFromPin(.screen, cache.tl_pin).?.screen;

            // Not cached since the cell contents may change.
            const br_pin: PageList.Pin = if (!sel.rectangle and
                cache.br_pin.rowAndCell().cell.wide == .spacer_head)
                cache.br_pin.rightWrap(1) orelse cache.br_pin
            else
                cache.br_pin;
            const br = s.pages.pointFromPin(.screen, br_pin).?.screen;

            // We need to determine if our selection is within the viewport.
            // The viewport is generally very small so the efficient way to
            // do this is to traverse the viewport pages and check for the
            // matching selection pages. Unused entries are skipped.
            const range = self.rowDataRange();
            for (
                row_pins[range.start..range.end],
                row_sels[range.start..range.end],
                row_dirties[range.start..range.end],
            ) |pin, *sel_bounds, *dirty| {
                const p = s.pages.pointFromPin(.screen, pin).?.screen;
                const row_sel = sel.containedRowCached(
                    s,
                    cache.tl_pin,
                    br_pin,
                    pin,
                    tl,
                    br,
                    p,
                ) orelse {
                    if (sel_bounds.* != null) {
                        sel_bounds.* = null;
                        dirty.* = true;
                        any_dirty = true;
                    }
                    continue;
                };
                const start = row_sel.start();
                const end = row_sel.end();
                assert(start.node == end.node);
                assert(start.x <= end.x);
                assert(start.y == end.y);

                const start_x = if (start.x > 0 and
                    start.rowAndCell().cell.wide == .spacer_tail)
                    start.x - 1
                else
                    start.x;

                sel_bounds.* = .{ start_x, end.x };
            }
        }

        // Handle dirty state.
        if (redraw) {
            // Fully redraw resets some other state.
            self.screen = t.screens.active_key;
            self.dirty = .full;

            // Note: we don't clear any row_data here because our rebuild
            // above did this.
        } else if (any_dirty and self.dirty == .false) {
            self.dirty = .partial;
        }

        // Clear our dirty flags
        t.flags.dirty = .{};
        s.dirty = .{};
    }

    /// Complete a prior `beginUpdate` call by performing any deferred
    /// work. At the time of writing, this denormalizes the pending
    /// style runs into the per-cell style data.
    ///
    /// This only reads and writes memory owned by the render state, so
    /// it is safe to call while the terminal is being modified (no
    /// terminal lock is required).
    pub fn endUpdate(self: *RenderState) void {
        // Common case: no styled rows were rebuilt.
        if (self.pending_styles.items.len == 0) return;

        const row_data = self.row_data.slice();
        const row_cells = row_data.items(.cells);
        const row_applied = row_data.items(.applied_styles);

        // Process the pending runs one row segment at a time. All the
        // runs for a row are appended contiguously by a single
        // beginUpdate, so a segment boundary is simply a change in y.
        const runs = self.pending_styles.items;
        var i: usize = 0;
        while (i < runs.len) {
            const y = runs[i].y;
            var j = i + 1;
            while (j < runs.len and runs[j].y == y) j += 1;
            const segment = runs[i..j];
            i = j;

            // Defensive: the row data may have changed shape if the
            // caller violated ordering (e.g. an error path skipped an
            // endUpdate between updates). Any update that changes
            // dimensions clears the pending list (redraw), so this
            // should never actually trigger, but the cost is trivial.
            if (y >= row_cells.len) continue;

            // If the segment matches the runs already denormalized
            // into this row's cell data then the per-cell styles are
            // already correct and the (comparatively large) fill can
            // be skipped entirely. This is the common case: rebuilt
            // rows usually keep their styling (only the text
            // changed), and full redraws of an unchanged screen keep
            // both.
            const applied = &row_applied[y];
            if (runsEql(applied.items, segment)) continue;

            for (segment) |run| {
                const styles = row_cells[run.y].slice().items(.style);
                const end = @min(run.end, styles.len);
                const start = @min(run.start, end);

                fillStyles(styles[start..end], run.style);
            }

            // Record what we applied so the next rebuild of this row
            // can skip the fill. beginUpdate reserved the capacity
            // (we cannot allocate here); if it doesn't fit (e.g.
            // segments merged across multiple begins without an end)
            // leave the cache empty, which never matches and simply
            // means the next rebuild applies its runs.
            applied.clearRetainingCapacity();
            if (applied.capacity >= segment.len) {
                applied.appendSliceAssumeCapacity(segment);
            }
        }
        self.pending_styles.clearRetainingCapacity();
    }

    /// Mark all render-state data as consumed by the renderer.
    ///
    /// This clears both the global dirty state and every per-row dirty flag.
    /// Callers that only consume part of a frame should clear the two layers
    /// individually instead.
    pub fn clean(self: *RenderState) void {
        self.dirty = .false;
        @memset(self.row_data.items(.dirty), false);
    }

    /// Returns the `row_data` index of the top row of the viewport.
    ///
    /// This is `overscan_request.above`, so it is zero without overscan
    /// and does not change from one update to the next. The viewport is
    /// the `rows` entries starting here.
    pub fn viewportStart(self: *const RenderState) usize {
        return self.overscan_request.above;
    }

    /// Converts a `row_data` index into a y position relative to the top
    /// of the viewport. Rows above the viewport are negative, and rows
    /// below it are `rows` or greater. For example, with one row of
    /// overscan above, index 0 is y = -1 and index 1 is y = 0.
    pub fn viewportY(self: *const RenderState, index: usize) isize {
        return @as(isize, @intCast(index)) - @as(isize, @intCast(self.viewportStart()));
    }

    /// A range of `row_data` indices. `start` is inclusive and `end` is
    /// exclusive, so it can be used directly as `range.start..range.end`.
    pub const RowDataRange = struct {
        start: usize,
        end: usize,
    };

    /// Returns the range of `row_data` that holds rows from the last
    /// update: the captured overscan rows above, the viewport, and the
    /// captured overscan rows below.
    ///
    /// Entries outside this range are unused. They contain leftover or
    /// uninitialized data and must not be read. Without overscan, this
    /// is always `0..rows`.
    pub fn rowDataRange(self: *const RenderState) RowDataRange {
        const vp = self.viewportStart();
        return .{
            .start = vp - self.overscan.above,
            .end = vp + self.rows + self.overscan.below,
        };
    }

    /// Fill a slice of styles with one value.
    ///
    /// This is equivalent to `@memset(dst, value)` but manually vectorized:
    /// `@memset` with a struct value lowers to a per-element field copy
    /// that reloads the source at every iteration because LLVM cannot
    /// prove the destination doesn't alias it. And, Zig 0.16 disables
    /// auto-vectorization due to an LLVM bug.
    ///
    /// This complexity is justified by accounting for ~10% of the endUpdate
    /// times under heavily styled cases.
    fn fillStyles(dst: []Style, value: Style) void {
        // Each element is written as two overlapping 16-byte vector
        // stores held in registers, which requires 16 <= size <= 32.
        const elem_size = @sizeOf(Style);
        comptime assert(elem_size >= 16 and elem_size <= 32);

        const V = @Vector(16, u8);
        const src: *align(@alignOf(Style)) const [elem_size]u8 = @ptrCast(&value);
        const lo = @as(*align(4) const V, @ptrCast(src[0..16])).*;
        const hi = @as(*align(1) const V, @ptrCast(src[elem_size - 16 ..][0..16])).*;

        const dst_bytes = std.mem.sliceAsBytes(dst);
        var off: usize = 0;
        for (0..dst.len) |_| {
            @as(*align(1) V, @ptrCast(dst_bytes[off..][0..16])).* = lo;
            @as(*align(1) V, @ptrCast(dst_bytes[off + elem_size - 16 ..][0..16])).* = hi;
            off += elem_size;
        }
    }

    /// Returns true if the two style run lists denormalize to
    /// identical per-cell style data. This is a semantic comparison
    /// (styles are compared field-wise, never by bytes, since padding
    /// is undefined).
    fn runsEql(a: []const StyleRun, b: []const StyleRun) bool {
        if (a.len != b.len) return false;
        for (a, b) |ar, br| {
            if (ar.start != br.start or
                ar.end != br.end or
                !ar.style.eql(br.style)) return false;
        }
        return true;
    }

    /// Update the highlights in the render state from the given flattened
    /// highlights. Because this uses flattened highlights, it does not require
    /// reading from the terminal state so it should be done outside of
    /// any critical sections.
    ///
    /// This will not clear any previous highlights, so the caller must
    /// manually clear them if desired.
    pub fn updateHighlightsFlattened(
        self: *RenderState,
        alloc: Allocator,
        tag: u8,
        hls: []const highlight.Flattened,
    ) Allocator.Error!void {
        // Fast path, we have no highlights!
        if (hls.len == 0) return;

        // This is, admittedly, horrendous. This is some low hanging fruit
        // to optimize. In my defense, screens are usually small, the number
        // of highlights is usually small, and this only happens on the
        // viewport outside of a locked area. Still, I'd love to see this
        // improved someday.

        // We need to track whether any row had a match so we can mark
        // the dirty state.
        var any_dirty: bool = false;

        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_dirties = row_data.items(.dirty);
        const row_pins = row_data.items(.pin);
        const row_serials = row_data.items(.serial);
        const row_highlights_slice = row_data.items(.highlights);
        const range = self.rowDataRange();
        for (
            row_arenas[range.start..range.end],
            row_pins[range.start..range.end],
            row_serials[range.start..range.end],
            row_highlights_slice[range.start..range.end],
            row_dirties[range.start..range.end],
        ) |*row_arena, row_pin, row_serial, *row_highlights, *dirty| {
            for (hls) |hl| {
                const chunks_slice = hl.chunks.slice();
                const nodes = chunks_slice.items(.node);
                const serials = chunks_slice.items(.serial);
                const starts = chunks_slice.items(.start);
                const ends = chunks_slice.items(.end);
                for (0.., nodes) |i, node| {
                    // If this node generation doesn't match or we're not
                    // within the row range, skip it. Both serials are copied
                    // values, so this never dereferences a node outside the
                    // terminal lock.
                    if (node != row_pin.node or
                        serials[i] != row_serial or
                        row_pin.y < starts[i] or
                        row_pin.y >= ends[i]) continue;

                    // We're a match!
                    var arena = row_arena.promote(alloc);
                    defer row_arena.* = arena.state;
                    const arena_alloc = arena.allocator();
                    try row_highlights.append(
                        arena_alloc,
                        .{
                            .tag = tag,
                            .range = .{
                                if (i == 0 and
                                    row_pin.y == starts[0])
                                    hl.top_x
                                else
                                    0,
                                if (i == nodes.len - 1 and
                                    row_pin.y == ends[nodes.len - 1] - 1)
                                    hl.bot_x
                                else
                                    self.cols - 1,
                            },
                        },
                    );

                    dirty.* = true;
                    any_dirty = true;
                }
            }
        }

        // Mark our dirty state.
        if (any_dirty and self.dirty == .false) self.dirty = .partial;
    }

    pub const StringMap = std.ArrayListUnmanaged(point.Coordinate);

    /// Convert the current render state contents to a UTF-8 encoded
    /// string written to the given writer. This will unwrap all the wrapped
    /// rows. This is useful for a minimal viewport search.
    ///
    /// This currently writes empty cell contents as \x00 and writes all
    /// blank lines. This is fine for our current usage (link search) but
    /// we can adjust this later.
    ///
    /// Only viewport rows are included, never overscan rows. The `y`
    /// values in `map` are viewport rows.
    ///
    /// NOTE: There is a limitation in that wrapped lines before/after
    /// the top/bottom line of the viewport are not included, since
    /// the render state cuts them off.
    pub fn string(
        self: *const RenderState,
        writer: *std.Io.Writer,
        map: ?struct {
            alloc: Allocator,
            map: *StringMap,
        },
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // This only covers the viewport, never overscan rows.
        const row_slice = self.row_data.slice();
        const vp_start = self.viewportStart();
        const row_rows = row_slice.items(.raw)[vp_start..][0..self.rows];
        const row_cells = row_slice.items(.cells)[vp_start..][0..self.rows];

        for (
            0..,
            row_rows,
            row_cells,
        ) |y, row, cells| {
            const cells_slice = cells.slice();
            for (
                0..,
                cells_slice.items(.raw),
                cells_slice.items(.grapheme),
            ) |x, cell, graphemes| {
                var len: usize = std.unicode.utf8CodepointSequenceLength(cell.codepoint()) catch
                    return error.WriteFailed;
                try writer.print("{u}", .{cell.codepoint()});
                if (cell.hasGrapheme()) {
                    for (graphemes) |cp| {
                        len += std.unicode.utf8CodepointSequenceLength(cp) catch
                            return error.WriteFailed;
                        try writer.print("{u}", .{cp});
                    }
                }

                if (map) |m| try m.map.appendNTimes(m.alloc, .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                }, len);
            }

            if (!row.wrap) {
                try writer.writeAll("\n");
                if (map) |m| try m.map.append(m.alloc, .{
                    .x = @intCast(cells_slice.len),
                    .y = @intCast(y),
                });
            }
        }
    }

    /// A set of coordinates representing cells.
    pub const CellSet = std.AutoArrayHashMapUnmanaged(point.Coordinate, void);

    /// Returns a map of the cells that match to an OSC8 hyperlink over the
    /// given point in the render state.
    ///
    /// IMPORTANT: The terminal must not have updated since the last call to
    /// `update`. If there is any chance the terminal has updated, the caller
    /// must first call `update` again to refresh the render state.
    ///
    /// For example, you may want to hold a lock for the duration of the
    /// update and hyperlink lookup to ensure no updates happen in between.
    ///
    /// Only viewport rows are searched, never overscan rows. Both the
    /// given point and the returned cells use viewport coordinates.
    pub fn linkCells(
        self: *const RenderState,
        alloc: Allocator,
        viewport_point: point.Coordinate,
    ) Allocator.Error!CellSet {
        var result: CellSet = .empty;
        errdefer result.deinit(alloc);

        // This only covers the viewport, never overscan rows.
        const row_slice = self.row_data.slice();
        const vp_start = self.viewportStart();
        const row_pins = row_slice.items(.pin)[vp_start..][0..self.rows];
        const row_cells = row_slice.items(.cells)[vp_start..][0..self.rows];

        // Our viewport point is sent in by the caller and can't be trusted.
        // If it is outside the valid area then just return empty because
        // we can't possibly have a link there.
        if (viewport_point.x >= self.cols or
            viewport_point.y >= self.rows) return result;

        // Grab our link ID
        const link_pin: PageList.Pin = row_pins[viewport_point.y];
        const link_page: *page.Page = link_pin.node.page();
        const link = link: {
            const rac = link_page.getRowAndCell(
                viewport_point.x,
                link_pin.y,
            );

            // The likely scenario is that our mouse isn't even over a link.
            if (!rac.cell.hyperlink) {
                @branchHint(.likely);
                return result;
            }

            const link_id = link_page.lookupHyperlink(rac.cell) orelse
                return result;
            break :link link_page.hyperlink_set.get(
                link_page.memory,
                link_id,
            );
        };

        for (
            0..,
            row_pins,
            row_cells,
        ) |y, pin, cells| {
            for (0.., cells.items(.raw)) |x, cell| {
                if (!cell.hyperlink) continue;

                const other_page: *page.Page = pin.node.page();
                const other = link: {
                    const rac = other_page.getRowAndCell(x, pin.y);
                    const link_id = other_page.lookupHyperlink(rac.cell) orelse continue;
                    break :link other_page.hyperlink_set.get(
                        other_page.memory,
                        link_id,
                    );
                };

                if (link.eql(
                    link_page.memory,
                    other,
                    other_page.memory,
                )) try result.put(alloc, .{
                    .y = @intCast(y),
                    .x = @intCast(x),
                }, {});
            }
        }

        return result;
    }
};

/// The Kitty graphics logic of the render state: finding the images that
/// programs show with placeholder cells, and positioning the relative
/// placements attached to them. See "Kitty Graphics Placeholders" in
/// the `RenderState` docs.
const Kitty = struct {
    /// The Kitty image storage key of a placement, or void when Kitty
    /// graphics are disabled.
    const PlacementKey = if (build_options.kitty_graphics)
        kitty_gfx.ImageStorage.PlacementKey
    else
        void;

    /// Information that only applies to Kitty graphics placements.
    /// Public as `RenderState.KittyPlacement`.
    pub const Placement = struct {
        kind: Kind,

        /// The placement ID, or zero if there isn't one. For a
        /// virtual run, this is the ID that the cells ask for. For a
        /// relative placement, this is the ID the program gave it.
        placement_id: u32,

        pub const Kind = lib.Enum(lib.target, &.{
            // Part of a virtual placement: one run of placeholder
            // cells in a single row. Its `rows` is always 1 and its
            // z-index is always -1.
            "virtual",

            // A relative placement attached to a virtual placement.
            // It is positioned from the top-left corner of the
            // virtual placement's cells in the viewport: the leftmost
            // column and topmost row that any of its cells use. This
            // matches Kitty.
            "relative",
        });
    };

    /// A run of neighboring Kitty graphics placeholder cells in one row
    /// that show one piece of one image.
    ///
    /// The fields up to `col` come from the cells and are set when the
    /// row is rebuilt. The rest are filled in by `beginUpdate`, which
    /// looks up the image and works out what to draw. Public as
    /// `RenderState.Placeholder`.
    pub const Placeholder = struct {
        /// The column of the first cell and the number of cells.
        x: size.CellCountInt,
        width: size.CellCountInt,

        /// The image and placement that the cells ask for. The cells
        /// encode these in their foreground and underline colors. A
        /// placement ID of zero means the image's virtual placement,
        /// whichever it is.
        image_id: u32,
        placement_id: u32,

        /// The piece of the image that the first cell shows. The image
        /// is divided into a grid of cells, and this is the row and
        /// column in that grid. Each following cell in the run shows the
        /// next column.
        row: u32,
        col: u32,

        /// Whether `beginUpdate` has looked at this run yet, and if so,
        /// whether it draws anything. `geometry` is only set when this
        /// is `visible`.
        state: State = .stale,

        /// The virtual placement this run shows, or null if there is
        /// none. Not set while `state` is `stale`.
        target: ?PlacementKey = null,

        /// What to draw. Only set when `state` is `visible`.
        geometry: Geometry = undefined,

        pub const State = enum(u8) {
            /// The run is new and hasn't been looked at yet.
            stale,

            /// There is nothing to draw, for example because the image
            /// doesn't exist or hasn't been fully received.
            hidden,

            /// The run draws part of an image, described by `geometry`.
            visible,
        };

        /// What a visible run draws. The fields have the same meaning
        /// as the fields of the same name in `RenderState.ImagePlacement`.
        pub const Geometry = struct {
            image_generation: u64,
            offset_x: u32,
            offset_y: u32,
            width: u32,
            height: u32,
            source_x: u32,
            source_y: u32,
            source_width: u32,
            source_height: u32,
        };
    };

    /// The Kitty graphics state of a render state (`RenderState.kitty`).
    const Data = struct {
        /// The image storage generation and the terminal size in pixels
        /// when the runs were last looked up. If any of these change,
        /// every run is looked up again. The pixel size stands in for
        /// the cell size. (A change in rows or columns forces a redraw,
        /// which looks up every run anyway.)
        generation: u64 = 0,
        width_px: u32 = 0,
        height_px: u32 = 0,

        /// True if a row was rebuilt with placeholder runs since the
        /// last lookup, so some runs are `stale`. Set by the row
        /// builder so that updates without new runs can skip the lookup.
        stale: bool = false,

        /// The relative placements attached to virtual placements, with
        /// everything except their position worked out. Rebuilt when
        /// the image storage generation changes.
        relative_roots: std.ArrayList(RelativeRoot) = .empty,

        /// The relative placements positioned by the last update.
        relative: std.ArrayList(RenderState.ImagePlacement) = .empty,

        const RelativeRoot = struct {
            /// The virtual placement at the start of the chain, and the
            /// total offset in cells from it to this placement.
            root: PlacementKey,
            horizontal_offset: i32,
            vertical_offset: i32,

            /// The placement, with `x` and `y` not yet set.
            placement: RenderState.ImagePlacement,
        };

        fn deinit(self: *Data, alloc: Allocator) void {
            self.relative_roots.deinit(alloc);
            self.relative.deinit(alloc);
        }
    };

    /// Work out what each placeholder run in the captured rows draws, and
    /// position the relative placements attached to virtual placements.
    /// This is part of `beginUpdate` and needs access to the terminal.
    fn update(
        state: *RenderState,
        alloc: Allocator,
        t: *const Terminal,
        redraw: bool,
        any_dirty: bool,
    ) Allocator.Error!void {
        const storage = &t.screens.active.kitty_images;

        // What a run draws depends only on the run itself, the image
        // storage and the cell size. If the storage and cell size didn't
        // change, only new runs (from rebuilt rows) need a lookup. After
        // a redraw we look up every run, because the redraw may be a
        // switch to the other screen, which has its own images.
        //
        // This runs on every update, so the common case (no placeholders
        // and nothing changed) must stay a few comparisons.
        const all = redraw or
            state.kitty.generation != storage.generation or
            state.kitty.width_px != t.width_px or
            state.kitty.height_px != t.height_px;
        if (!all and !state.kitty.stale) {
            @branchHint(.likely);

            // No runs to look up. Relative placements only move when rows
            // change, and there are none without roots.
            if (!any_dirty or state.kitty.relative_roots.items.len == 0) return;
        }

        try @call(
            .never_inline,
            updateSlow,
            .{ state, alloc, t, all },
        );
    }

    /// The part of `update` that does the work. It is kept out of line
    /// so that the common case in `update` stays small.
    fn updateSlow(
        state: *RenderState,
        alloc: Allocator,
        t: *const Terminal,
        all: bool,
    ) Allocator.Error!void {
        const storage = &t.screens.active.kitty_images;
        if (all) {
            state.kitty.generation = storage.generation;
            state.kitty.width_px = t.width_px;
            state.kitty.height_px = t.height_px;
            try relativeRoots(state, alloc, t);
        }

        const row_data = state.row_data.slice();
        const row_placeholders = row_data.items(.placeholders);
        if (all or state.kitty.stale) {
            state.kitty.stale = false;
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;
            const row_pins = row_data.items(.pin);
            const range = state.rowDataRange();
            for (
                row_pins[range.start..range.end],
                row_placeholders[range.start..range.end],
            ) |pin, runs| {
                for (runs.items) |*run| {
                    if (!all and run.state != .stale) continue;
                    resolvePlaceholder(
                        storage,
                        pin,
                        run,
                        cell_width,
                        cell_height,
                    );
                }
            }
        }

        // Position each relative placement from the top-left corner of
        // its virtual placement's cells in the viewport, using the
        // smallest column and the smallest row of those cells. If the
        // viewport has none of those cells, the relative placement isn't
        // drawn, which matches Kitty. There are rarely more than a few
        // relative placements, so a simple scan of the runs for each one
        // is fine.
        state.kitty.relative.clearRetainingCapacity();
        if (state.kitty.relative_roots.items.len == 0) return;
        const vp_start = state.viewportStart();
        const vp_placeholders = row_placeholders[vp_start..][0..state.rows];
        for (state.kitty.relative_roots.items) |root| {
            var origin: ?struct { x: i64, y: i64 } = null;
            for (vp_placeholders, 0..) |runs, y| {
                for (runs.items) |run| {
                    const target = run.target orelse continue;
                    if (!target.eql(root.root)) continue;
                    if (origin) |*o| {
                        o.x = @min(o.x, run.x);
                        o.y = @min(o.y, @as(i64, @intCast(y)));
                    } else origin = .{ .x = run.x, .y = @intCast(y) };
                }
            }
            const o = origin orelse continue;

            // The position relative to the viewport, which can be
            // negative. Skip placements entirely outside the viewport.
            const p = root.placement;
            const x: i64 = o.x + root.horizontal_offset;
            const y: i64 = o.y + root.vertical_offset;
            if (y >= state.rows or y + p.rows - 1 < 0) continue;
            if (x >= state.cols or x + p.cols - 1 < 0) continue;

            var positioned = p;
            positioned.x = std.math.cast(i32, x) orelse continue;
            positioned.y = std.math.cast(i32, y) orelse continue;
            try state.kitty.relative.append(alloc, positioned);
        }
    }

    /// Rebuild `state.kitty.relative_roots` from the image storage.
    /// Everything about a relative placement except its position depends
    /// only on the storage and the cell size, so this only runs when one
    /// of those changes.
    fn relativeRoots(
        state: *RenderState,
        alloc: Allocator,
        t: *const Terminal,
    ) Allocator.Error!void {
        const storage = &t.screens.active.kitty_images;
        state.kitty.relative_roots.clearRetainingCapacity();
        var it = storage.placements.iterator();
        while (it.next()) |kv| {
            const rel = switch (kv.value_ptr.location) {
                .relative => |rel| rel,
                .pin, .virtual => continue,
            };

            // Follow the chain of parents to the placement at its start.
            // A broken chain is never drawn. Chains that start at a fixed
            // position are drawn from the image storage instead.
            const chain = storage.resolveChain(rel) orelse continue;
            if (chain.root.location != .virtual) continue;

            const image = storage.imageById(kv.key_ptr.image_id) orelse continue;
            if (image.data.isPending()) continue;

            // The size is zero when the terminal has no cell size in
            // pixels. Then there is nothing to draw.
            const p = kv.value_ptr;
            const grid = p.gridSize(image, t);
            if (grid.cols == 0 or grid.rows == 0) continue;
            const dest = p.pixelSize(image, t);
            if (dest.width == 0 or dest.height == 0) continue;
            const offset = p.cellOffset(t);
            const source = p.sourceRect(image);

            try state.kitty.relative_roots.append(alloc, .{
                .root = chain.root_key,
                .horizontal_offset = chain.horizontal_offset,
                .vertical_offset = chain.vertical_offset,
                .placement = .{
                    .protocol = .{ .kitty = .{
                        .kind = .relative,
                        .placement_id = switch (kv.key_ptr.placement_id.tag) {
                            .external => kv.key_ptr.placement_id.id,
                            .internal => 0,
                        },
                    } },
                    .image_id = kv.key_ptr.image_id,
                    .image_generation = image.generation,
                    // Kitty draws negative z-indexes below text. Below
                    // minInt(i32) / 2 they are also below backgrounds.
                    .layer = if (p.z < std.math.minInt(i32) / 2)
                        .below_background
                    else if (p.z < 0)
                        .below_text
                    else
                        .above_text,
                    .z = p.z,
                    .x = 0,
                    .y = 0,
                    .cols = grid.cols,
                    .rows = grid.rows,
                    .offset_x = offset.x,
                    .offset_y = offset.y,
                    .width = dest.width,
                    .height = dest.height,
                    .source_x = source.x,
                    .source_y = source.y,
                    .source_width = source.width,
                    .source_height = source.height,
                },
            });
        }
    }

    /// Look up what one placeholder run draws and store it in the run.
    /// `row_pin` is the pin of the run's row.
    fn resolvePlaceholder(
        storage: *const kitty_gfx.ImageStorage,
        row_pin: PageList.Pin,
        run: *Placeholder,
        cell_width: u32,
        cell_height: u32,
    ) void {
        run.state = .hidden;
        run.target = null;

        // Remember the virtual placement even if the image can't be
        // drawn. Relative placements attached to it still need the
        // position of these cells.
        const target = storage.placeholderTarget(
            run.image_id,
            run.placement_id,
        ) orelse return;
        run.target = target.key;

        const image = storage.imageById(run.image_id) orelse return;
        if (image.data.isPending()) return;

        // Without a cell size in pixels, there is no size to draw at.
        if (cell_width == 0 or cell_height == 0) return;

        var pin = row_pin;
        pin.x = run.x;
        const vp: kitty_gfx.unicode.Placement = .{
            .pin = pin,
            .image_id = run.image_id,
            .placement_id = run.placement_id,
            .col = run.col,
            .row = run.row,
            .width = run.width,
            .height = 1,
        };
        const rp = vp.renderPlacement(
            &target.placement,
            &image,
            cell_width,
            cell_height,
        ) catch |err| {
            log.warn("error resolving virtual placement err={}", .{err});
            return;
        };
        if (rp.dest_width == 0 or rp.dest_height == 0) return;

        run.geometry = .{
            .image_generation = image.generation,
            .offset_x = rp.offset_x,
            .offset_y = rp.offset_y,
            .width = rp.dest_width,
            .height = rp.dest_height,
            .source_x = rp.source_x,
            .source_y = rp.source_y,
            .source_width = rp.source_width,
            .source_height = rp.source_height,
        };
        run.state = .visible;
    }

    /// Groups Kitty placeholder cells into runs as the row scan visits
    /// them. Feed it placeholder cells from left to right. A gap between
    /// two cells (any cell that isn't fed) ends the current run.
    const PlaceholderDecoder = struct {
        list: *std.ArrayList(RenderState.Placeholder),
        alloc: Allocator,
        stale: *bool,
        run: ?kitty_gfx.unicode.IncompletePlacement = null,
        start: usize = 0,
        end: usize = 0,

        inline fn feed(
            self: *PlaceholderDecoder,
            x: usize,
            style: *const Style,
            cps: []const u21,
        ) Allocator.Error!void {
            const curr: kitty_gfx.unicode.IncompletePlacement = .init(style, cps);
            if (self.run) |*prev| {
                if (x == self.end and prev.append(&curr)) {
                    self.end += 1;
                    return;
                }
                try self.flush();
            }
            self.run = curr.start();
            self.start = x;
            self.end = x + 1;
        }

        fn flush(self: *PlaceholderDecoder) Allocator.Error!void {
            const run = self.run orelse return;
            self.run = null;
            self.stale.* = true;
            try self.list.append(self.alloc, .{
                .x = @intCast(self.start),
                .width = @intCast(run.width),
                .image_id = run.imageId(),
                .placement_id = run.placement_id orelse 0,
                .row = run.row.?,
                .col = run.col.?,
            });
        }
    };
};

/// The number of rows/cells we scan as a single group when looking for
/// dirty rows or special cells. Rows and cells are small packed structs
/// so a group is scanned with a handful of vector operations.
const scan_group_len = 8;

/// Group scan helper for the row dirty flag. A row that matches has
/// its dirty flag unset.
const RowDirtyMask = page.Mask(
    page.Row,
    &.{"dirty"},
    scan_group_len,
);

/// Group scan helper for the cell fields that require managed memory
/// handling. A cell that matches is a plain (possibly zero) codepoint
/// with a default style, requiring no work beyond the raw copy. See
/// RowBuilder.row.
const CellSpecialMask = page.Mask(page.Cell, &.{
    "content_tag",
    "style_id",
}, scan_group_len);

/// Internal helper for RenderState.update that rebuilds a single row of
/// the render state from the current page contents.
const RowBuilder = struct {
    alloc: Allocator,
    cols: usize,
    arenas: []ArenaAllocator.State,
    raws: []page.Row,
    cells: []std.MultiArrayList(RenderState.Cell),
    sels: []?[2]size.CellCountInt,
    highlights: []std.ArrayList(RenderState.Highlight),
    placeholders: []std.ArrayList(RenderState.Placeholder),
    kitty_stale: *bool,
    dirties: []bool,
    pending_styles: *std.ArrayList(RenderState.StyleRun),
    applied_styles: []std.ArrayList(RenderState.StyleRun),

    fn row(
        b: *const RowBuilder,
        p: *page.Page,
        page_row: *const page.Row,
        vy: usize,
    ) Allocator.Error!void {
        // Promote our arena. State is copied by value so we need to
        // restore it on all exit paths so we don't leak memory.
        var arena = b.arenas[vy].promote(b.alloc);
        defer b.arenas[vy] = arena.state;

        // Reset our per-row state if we're rebuilding this row. A
        // non-zero cell length means the row was populated by a prior
        // update.
        if (b.cells[vy].len > 0) {
            _ = arena.reset(.retain_capacity);
            b.sels[vy] = null;
            b.highlights[vy] = .empty;
            b.placeholders[vy] = .empty;
        }
        b.dirties[vy] = true;

        // Get all our cells in the page.
        const page_cells: []const page.Cell = page_row.cells.ptr(p.memory)[0..b.cols];

        // Copy our raw row data
        b.raws[vy] = page_row.*;

        // Note: our cells MultiArrayList uses our general allocator.
        // We do this on purpose because as rows become dirty, we do
        // not want to reallocate space for cells (which are large). This
        // was a source of huge slowdown.
        //
        // Our per-row arena is only used for temporary allocations
        // pertaining to cells directly (e.g. graphemes, hyperlinks).
        const cells: *std.MultiArrayList(RenderState.Cell) = &b.cells[vy];
        if (cells.len != b.cols) {
            // The cell storage (including the per-cell style data) is
            // being reallocated, so the applied style cache no longer
            // describes it. Clear it before the resize so an error
            // can't leave it stale.
            b.applied_styles[vy].clearRetainingCapacity();
            try cells.resize(b.alloc, b.cols);
        }

        // We always copy our raw cell data. In the case we have no
        // managed memory, we can skip setting any other fields.
        //
        // This is an important optimization. For plain-text screens
        // this ends up being something around 300% faster based on
        // the `screen-clone` benchmark.
        const cells_slice = cells.slice();
        fastmem.copy(
            page.Cell,
            cells_slice.items(.raw),
            page_cells,
        );
        // Rows with Kitty placeholders are rare. They get their own copy
        // of the scan below, so other rows pay nothing for them. These
        // rows are scanned even without managed memory, because a
        // placeholder cell can be a plain character with no style.
        const placeholder_row = build_options.kitty_graphics and
            page_row.kitty_virtual_placeholder;
        if (!page_row.managedMemory() and !placeholder_row) return;

        const arena_alloc = arena.allocator();
        if (placeholder_row) {
            @branchHint(.unlikely);
            var decoder: Kitty.PlaceholderDecoder = .{
                .list = &b.placeholders[vy],
                .alloc = arena_alloc,
                .stale = b.kitty_stale,
            };
            try b.scan(true, p, page_cells, cells_slice, arena_alloc, vy, &decoder);
            try decoder.flush();
            return;
        }

        try b.scan(false, p, page_cells, cells_slice, arena_alloc, vy, {});
    }

    /// The managed memory scan of `row`. When `placeholders` is true,
    /// this also feeds every Kitty placeholder cell to the decoder.
    ///
    /// This is deliberately not inline. Each value of `placeholders`
    /// produces its own function, so the placeholder handling can't
    /// change how the common version (without placeholders) is
    /// optimized.
    fn scan(
        b: *const RowBuilder,
        comptime placeholders: bool,
        p: *page.Page,
        page_cells: []const page.Cell,
        cells_slice: std.MultiArrayList(RenderState.Cell).Slice,
        arena_alloc: Allocator,
        vy: usize,
        decoder: if (placeholders) *Kitty.PlaceholderDecoder else void,
    ) Allocator.Error!void {
        const cells_grapheme = cells_slice.items(.grapheme);
        const n = page_cells.len;
        const runs_start = b.pending_styles.items.len;
        var x: usize = 0;
        scan: while (x < n) {
            // Skip runs of plain cells a group at a time. Cells that
            // need managed handling are often rare even within rows that
            // have managed memory (e.g. a row is "styled" if a single
            // cell has a style) so groups are skipped with a few vector
            // operations. On placeholder rows a plain cell can be a
            // placeholder, so those rows check each cell instead.
            if (!placeholders) while (n - x >= CellSpecialMask.group_len) {
                if (!CellSpecialMask.match(page_cells, x)) break;
                x += CellSpecialMask.group_len;
            };

            // Scalar scan to the next special cell.
            while (true) {
                if (x >= n) break :scan;
                if (!CellSpecialMask.matchScalar(page_cells[x])) break;
                if (placeholders and
                    page_cells[x].codepoint() == kitty_gfx.unicode.placeholder)
                {
                    try decoder.feed(x, &.{}, &.{});
                }
                x += 1;
            }

            const page_cell = &page_cells[x];

            switch (page_cell.content_tag) {
                // Single-codepoint styled cells are by far the most
                // common special cells, and they usually come in long
                // runs sharing one style ID (e.g. a fully styled row
                // usually uses a single style). Find the run and record
                // it: this does one style lookup per run and defers the
                // (large) per-cell fill to endUpdate, outside of any
                // terminal locks.
                .codepoint => {
                    @branchHint(.likely);
                    const sid = page_cell.style_id;
                    assert(sid > 0); // special + codepoint implies styled
                    const style_val: Style = p.styles.get(p.memory, sid).*;

                    // A cell continues the run if its masked special
                    // bits are exactly the style ID of the run (in
                    // particular the content tag must be a plain
                    // codepoint). We can check groups of cells at a
                    // time this way.
                    const pattern = CellSpecialMask.pattern(page_cell.*);
                    const start = x;
                    x += 1;
                    while (n - x >= CellSpecialMask.group_len) {
                        if (!CellSpecialMask.eql(
                            page_cells,
                            x,
                            pattern,
                        )) break;
                        x += CellSpecialMask.group_len;
                    }
                    while (x < n) : (x += 1) {
                        if (!CellSpecialMask.eqlScalar(
                            page_cells[x],
                            pattern,
                        )) break;
                    }

                    try b.pending_styles.append(b.alloc, .{
                        .y = @intCast(vy),
                        .start = @intCast(start),
                        .end = @intCast(x),
                        .style = style_val,
                    });

                    // A placeholder can leave out its row and column
                    // (it then continues the run to its left), which
                    // makes it a plain styled cell like these. Every
                    // cell in this style run has the same style.
                    if (placeholders) for (start..x) |px| {
                        if (page_cells[px].codepoint() != kitty_gfx.unicode.placeholder) continue;
                        try decoder.feed(px, &style_val, &.{});
                    };
                },

                // If we have a multi-codepoint grapheme, look it up and
                // set our content type. Note grapheme cells may also
                // be styled. The style must be recorded as a run (rather
                // than written directly) so that it is ordered correctly
                // relative to possibly-stale runs from prior updates.
                .codepoint_grapheme => {
                    const style_val: Style = if (page_cell.style_id > 0) style: {
                        const style_val = p.styles.get(
                            p.memory,
                            page_cell.style_id,
                        ).*;
                        try b.pending_styles.append(b.alloc, .{
                            .y = @intCast(vy),
                            .start = @intCast(x),
                            .end = @intCast(x + 1),
                            .style = style_val,
                        });
                        break :style style_val;
                    } else .{};
                    const cps = try arena_alloc.dupe(
                        u21,
                        p.lookupGrapheme(page_cell) orelse &.{},
                    );
                    cells_grapheme[x] = cps;

                    // Most placeholders give their row and column in
                    // the image as combining characters, so most are
                    // handled here, using the style and grapheme we
                    // already have.
                    if (placeholders and
                        page_cell.codepoint() == kitty_gfx.unicode.placeholder)
                    {
                        try decoder.feed(x, &style_val, cps);
                    }
                    x += 1;
                },

                // Background-color-only cells. The style is derived
                // entirely from the cell contents. Consecutive cleared
                // cells with the same background are bit-identical, so
                // we run-detect on full equality (e.g. a line cleared
                // with a background color pending is one run).
                .bg_color_rgb, .bg_color_palette => {
                    const style_val: Style = switch (page_cell.content_tag) {
                        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
                            .r = page_cell.content.color_rgb.r,
                            .g = page_cell.content.color_rgb.g,
                            .b = page_cell.content.color_rgb.b,
                        } } },
                        .bg_color_palette => .{ .bg_color = .{
                            .palette = page_cell.content.color_palette.data,
                        } },
                        else => unreachable,
                    };

                    const first_bits = CellSpecialMask.bits(page_cell.*);
                    const start = x;
                    x += 1;
                    while (n - x >= CellSpecialMask.group_len) {
                        if (!CellSpecialMask.eqlExact(
                            page_cells,
                            x,
                            first_bits,
                        )) break;
                        x += CellSpecialMask.group_len;
                    }
                    while (x < n) : (x += 1) {
                        if (CellSpecialMask.bits(page_cells[x]) != first_bits)
                            break;
                    }

                    try b.pending_styles.append(b.alloc, .{
                        .y = @intCast(vy),
                        .start = @intCast(start),
                        .end = @intCast(x),
                        .style = style_val,
                    });
                },
            }
        }

        // Reserve the applied style cache capacity for the runs we
        // appended so that endUpdate (which cannot allocate) is able
        // to record what it applies. See Row.applied_styles.
        const runs_added = b.pending_styles.items.len - runs_start;
        if (runs_added > 0) try b.applied_styles[vy].ensureTotalCapacity(
            b.alloc,
            runs_added,
        );
    }
};

test "styled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    // This fills the screen up
    try t.decaln();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
}

test "basic text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABCD");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    try testing.expectEqual('A', cells[0].get(0).raw.codepoint());
    try testing.expectEqual('B', cells[0].get(1).raw.codepoint());
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual('D', cells[0].get(3).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(4).raw.codepoint());
}

test "styled text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mA"); // Bold
    s.nextSlice("\x1b[0;3mB"); // Italic
    s.nextSlice("\x1b[0;4mC"); // Underline

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual('B', cell.raw.codepoint());
        try testing.expect(!cell.style.flags.bold);
        try testing.expect(cell.style.flags.italic);
    }
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(3).raw.codepoint());
}

/// Verifies that an incrementally updated render state has identical
/// contents to a from-scratch rebuild. This is the load-bearing check
/// for our dirty tracking: if any terminal operation changes row
/// contents without setting a dirty signal that `update` honors
/// (terminal dirty, screen dirty, page dirty, row dirty, viewport pin,
/// or dimensions), the incremental state will contain stale rows and
/// this comparison will fail.
fn testCompareStates(
    incremental: *const RenderState,
    fresh: *const RenderState,
) !void {
    const testing = std.testing;

    // Row metadata that is allowed to be stale in an incremental
    // update. Dirty tracking only guarantees that VISUAL changes are
    // flagged (see page.Row.dirty); these fields are non-visual
    // metadata that the terminal may change without dirtying the row
    // (e.g. Screen.cursorResetWrap clears wrap flags without a dirty
    // mark). This staleness predates the chunked update
    // implementation; it is present in the row-iterator implementation
    // as well.
    const StaleOkMask = page.Mask(page.Row, &.{
        "wrap",
        "wrap_continuation",
        "semantic_prompt",
        "dirty",
    }, 1);

    try testing.expectEqual(fresh.rows, incremental.rows);
    try testing.expectEqual(fresh.cols, incremental.cols);
    try testing.expectEqual(fresh.cursor.active, incremental.cursor.active);
    try testing.expectEqual(fresh.cursor.viewport, incremental.cursor.viewport);
    try testing.expectEqual(
        @as(page.Cell.Backing, @bitCast(fresh.cursor.cell)),
        @as(page.Cell.Backing, @bitCast(incremental.cursor.cell)),
    );

    // Unused entries (outside rowDataRange) may hold anything, so
    // we only compare the populated range.
    try testing.expectEqual(fresh.overscan, incremental.overscan);
    try testing.expectEqual(fresh.rowDataRange(), incremental.rowDataRange());
    const range = fresh.rowDataRange();

    const inc_data = incremental.row_data.slice();
    const new_data = fresh.row_data.slice();
    try testing.expectEqual(new_data.len, inc_data.len);
    for (range.start..range.end) |y| {
        errdefer std.log.warn("mismatch on row y={}", .{y});

        // Pins must match exactly.
        const inc_pin = inc_data.items(.pin)[y];
        const new_pin = new_data.items(.pin)[y];
        try testing.expectEqual(new_pin.node, inc_pin.node);
        try testing.expectEqual(new_pin.y, inc_pin.y);

        // Raw row data must match, except for non-visual metadata
        // fields which may legitimately be stale (see StaleOkMask).
        const inc_row = inc_data.items(.raw)[y];
        const new_row = new_data.items(.raw)[y];
        try testing.expectEqual(
            StaleOkMask.strip(new_row),
            StaleOkMask.strip(inc_row),
        );

        const inc_cells = inc_data.items(.cells)[y].slice();
        const new_cells = new_data.items(.cells)[y].slice();
        try testing.expectEqual(new_cells.len, inc_cells.len);
        const managed = new_row.managedMemory();
        for (0..new_cells.len) |x| {
            errdefer std.log.warn("mismatch on cell x={}", .{x});

            // Raw cell contents must match.
            const inc_cell = inc_cells.items(.raw)[x];
            const new_cell = new_cells.items(.raw)[x];
            try testing.expectEqual(
                @as(page.Cell.Backing, @bitCast(new_cell)),
                @as(page.Cell.Backing, @bitCast(inc_cell)),
            );

            // The style is only defined if the cell is styled or is
            // a bg-color cell within a row that has managed memory.
            if (new_cell.style_id != 0 or
                (managed and switch (new_cell.content_tag) {
                    .bg_color_rgb, .bg_color_palette => true,
                    else => false,
                }))
            {
                try testing.expect(std.meta.eql(
                    new_cells.items(.style)[x],
                    inc_cells.items(.style)[x],
                ));
            }

            // Graphemes are only defined for grapheme cells.
            if (new_cell.content_tag == .codepoint_grapheme) {
                try testing.expectEqualSlices(
                    u21,
                    new_cells.items(.grapheme)[x],
                    inc_cells.items(.grapheme)[x],
                );
            }
        }
    }
}

test "incremental updates match full rebuild" {
    try testIncrementalMatchesFresh(.{});
}

test "incremental updates match full rebuild with overscan" {
    try testIncrementalMatchesFresh(.{ .above = 2, .below = 1 });
}

fn testIncrementalMatchesFresh(request: RenderState.Overscan) !void {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Deterministic so failures are reproducible.
    var prng = std.Random.DefaultPrng.init(0xB0BA_CAFE);
    const rand = prng.random();

    var t = try Terminal.init(io, alloc, .{
        .cols = 20,
        .rows = 8,
        .max_scrollback_bytes = 500,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var inc: RenderState = .empty;
    defer inc.deinit(alloc);
    inc.overscan_request = request;

    var buf: [64]u8 = undefined;
    for (0..300) |_| {
        // Perform a random batch of operations between updates.
        for (0..rand.intRangeAtMost(usize, 1, 6)) |_| {
            switch (rand.intRangeAtMost(u8, 0, 18)) {
                // Plain text (possibly wrapping and scrolling).
                0, 1, 2 => for (0..rand.intRangeAtMost(usize, 1, 30)) |_| {
                    s.nextSlice(&.{rand.intRangeAtMost(u8, 'A', 'Z')});
                },

                // Newlines to build scrollback and trigger pruning.
                3, 4 => for (0..rand.intRangeAtMost(usize, 1, 10)) |_| {
                    s.nextSlice("x\r\n");
                },

                // Cursor movement.
                5 => s.nextSlice(try std.mem.print(&buf, "\x1b[{};{}H", .{
                    rand.intRangeAtMost(u16, 1, 8),
                    rand.intRangeAtMost(u16, 1, 20),
                })),

                // Styling: bold, truecolor bg, palette fg, reset.
                6 => s.nextSlice(switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => "\x1b[1m",
                    1 => "\x1b[48;2;30;60;90m",
                    2 => "\x1b[38;5;120m",
                    else => "\x1b[0m",
                }),

                // Erase ops (EL, ED variants including scrollback).
                7 => s.nextSlice(switch (rand.intRangeAtMost(u8, 0, 4)) {
                    0 => "\x1b[K",
                    1 => "\x1b[1K",
                    2 => "\x1b[J",
                    3 => "\x1b[2J",
                    else => "\x1b[3J",
                }),

                // Insert/delete lines (row rotations within regions).
                8 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}L", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                9 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}M", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),

                // Scroll up/down (page-dirty row rotations).
                10 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}S", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                11 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}T", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),

                // Set/reset scroll regions to exercise bounded scrolls.
                12 => {
                    const top = rand.intRangeAtMost(u16, 1, 4);
                    const bot = rand.intRangeAtMost(u16, top + 1, 8);
                    s.nextSlice(try std.mem.print(
                        &buf,
                        "\x1b[{};{}r",
                        .{ top, bot },
                    ));
                },

                // Insert/delete/erase chars within a row.
                13 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}@", .{
                    rand.intRangeAtMost(u16, 1, 5),
                })),
                14 => s.nextSlice(try std.mem.print(&buf, "\x1b[{}P", .{
                    rand.intRangeAtMost(u16, 1, 5),
                })),

                // Reverse index (scroll down at top).
                15 => s.nextSlice("\x1bM"),

                // Wide chars and multi-codepoint graphemes.
                16 => s.nextSlice("字👨‍👩‍👧"),

                // Alternate screen switching (screen key redraw path).
                17 => s.nextSlice(if (rand.boolean())
                    "\x1b[?1049h"
                else
                    "\x1b[?1049l"),

                // DECALN full-screen fill.
                18 => s.nextSlice("\x1b#8"),

                else => unreachable,
            }
        }

        // Occasionally scroll the viewport into scrollback and back.
        switch (rand.intRangeAtMost(u8, 0, 9)) {
            0 => t.scrollViewport(.{ .delta = -3 }),
            1 => t.scrollViewport(.{ .delta = 2 }),
            2 => t.scrollViewport(.bottom),
            3 => t.scrollViewport(.top),
            else => {},
        }

        // Update our incremental state first: it must consume the dirty
        // state. The fresh state always fully rebuilds (its dimensions
        // start empty so it always redraws) and so does not depend on
        // any dirty flags.
        try inc.update(alloc, &t);

        var fresh: RenderState = .empty;
        defer fresh.deinit(alloc);
        fresh.overscan_request = request;
        try fresh.update(alloc, &t);

        try testCompareStates(&inc, &fresh);
    }
}

test "begin and end update" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mAB"); // Bold
    s.nextSlice("\x1b[0;3mC"); // Italic

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.beginUpdate(alloc, &t);

    // We should have pending style runs on row 0: one for the bold
    // run and one for the italic run.
    {
        const runs = state.pending_styles.items;
        try testing.expectEqual(2, runs.len);
        try testing.expectEqual(0, runs[0].y);
        try testing.expectEqual(0, runs[0].start);
        try testing.expectEqual(2, runs[0].end);
        try testing.expect(runs[0].style.flags.bold);
        try testing.expectEqual(0, runs[1].y);
        try testing.expectEqual(2, runs[1].start);
        try testing.expectEqual(3, runs[1].end);
        try testing.expect(runs[1].style.flags.italic);
    }

    // End our update. This should denormalize the runs into cells
    // and clear the pending runs.
    state.endUpdate();
    {
        try testing.expectEqual(0, state.pending_styles.items.len);

        const row_data = state.row_data.slice();
        const cells = row_data.items(.cells);
        try testing.expect(cells[0].get(0).style.flags.bold);
        try testing.expect(cells[0].get(1).style.flags.bold);
        try testing.expect(cells[0].get(2).style.flags.italic);
    }
}

test "endUpdate skips unchanged style runs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mAB"); // Bold

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // The applied cache should record the bold run for row 0.
    {
        const row_data = state.row_data.slice();
        const applied = row_data.items(.applied_styles);
        try testing.expectEqual(1, applied[0].items.len);
        try testing.expect(applied[0].items[0].style.flags.bold);
        try testing.expect(state.row_data.items(.cells)[0].get(0).style.flags.bold);
    }

    // Rewrite the text without changing the styling: the row is
    // rebuilt, the run matches the cache, and the styles must remain
    // correct (the fill is skipped internally).
    s.nextSlice("\x1b[1;1H\x1b[1mXY");
    try state.update(alloc, &t);
    {
        const cells = &state.row_data.items(.cells)[0];
        try testing.expectEqual('X', cells.get(0).raw.codepoint());
        try testing.expect(cells.get(0).style.flags.bold);
        try testing.expect(cells.get(1).style.flags.bold);
    }

    // Change the styling: the cache mismatches and the new styles
    // must be applied and recorded.
    s.nextSlice("\x1b[1;1H\x1b[0;3mZW"); // Italic
    try state.update(alloc, &t);
    {
        const cells = &state.row_data.items(.cells)[0];
        try testing.expectEqual('Z', cells.get(0).raw.codepoint());
        try testing.expect(!cells.get(0).style.flags.bold);
        try testing.expect(cells.get(0).style.flags.italic);

        const applied = state.row_data.items(.applied_styles);
        try testing.expectEqual(1, applied[0].items.len);
        try testing.expect(applied[0].items[0].style.flags.italic);
    }
}

test "bg color cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Write a styled cell (so the row has managed memory) then erase
    // the rest of the line with a palette background pending. The
    // erase produces bg_color content cells rather than styled cells.
    s.nextSlice("\x1b[1mA\x1b[48;5;1m\x1b[K");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const cells = row_data.items(.cells);
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    for (1..10) |x| {
        const cell = cells[0].get(x);
        try testing.expectEqual(
            page.Cell.ContentTag.bg_color_palette,
            cell.raw.content_tag,
        );
        try testing.expectEqual(
            Style.Color{ .palette = 1 },
            cell.style.bg_color,
        );
    }
}

test "grapheme" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A");
    s.nextSlice("👨‍"); // this has a ZWJ

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual(0x1F468, cell.raw.codepoint());
        try testing.expectEqual(.wide, cell.raw.wide);
        try testing.expectEqualSlices(u21, &.{0x200D}, cell.grapheme);
    }
    {
        const cell = cells[0].get(2);
        try testing.expectEqual(0, cell.raw.codepoint());
        try testing.expectEqual(.spacer_tail, cell.raw.wide);
    }
}

test "cursor state in viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\x1b[H");

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Initial update
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(0, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(0, state.cursor.viewport.?.y);
    try testing.expectEqual('A', state.cursor.cell.codepoint());
    try testing.expect(state.cursor.style.default());

    // Set a style on the cursor
    s.nextSlice("\x1b[1m"); // Bold
    try state.update(alloc, &t);
    try testing.expect(!state.cursor.style.default());
    try testing.expect(state.cursor.style.flags.bold);
    s.nextSlice("\x1b[0m"); // Reset style

    // Move cursor to 2,1
    s.nextSlice("\x1b[2;3H");
    try state.update(alloc, &t);
    try testing.expectEqual(2, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(2, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);
}

test "cursor state out of viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 2,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nB\r\nC\r\nD\r\n");

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Initial update
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);

    // Scroll the viewport
    t.scrollViewport(.top);
    try state.update(alloc, &t);

    // Set a style on the cursor
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expect(state.cursor.viewport == null);
}

test "dirty state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // First update should trigger redraw due to resize
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);

    // Reset dirty flag and dirty rows
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }

    // Second update with no changes - no dirty rows
    try state.update(alloc, &t);
    try testing.expectEqual(.false, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        for (dirty) |d| try testing.expect(!d);
    }

    // Write to first line
    s.nextSlice("A");
    try state.update(alloc, &t);
    try testing.expectEqual(.partial, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        try testing.expect(dirty[0]); // First row dirty
        try testing.expect(!dirty[1]); // Second row clean
    }
}

test "colors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Default colors
    try state.update(alloc, &t);

    // Change cursor color
    s.nextSlice("\x1b]12;#FF0000\x07");
    try state.update(alloc, &t);

    const c = state.colors.cursor.?;
    try testing.expectEqual(0xFF, c.r);
    try testing.expectEqual(0, c.g);
    try testing.expectEqual(0, c.b);

    // Change palette color 0 to White
    s.nextSlice("\x1b]4;0;#FFFFFF\x07");
    try state.update(alloc, &t);
    const p0 = state.colors.palette[0];
    try testing.expectEqual(0xFF, p0.r);
    try testing.expectEqual(0xFF, p0.g);
    try testing.expectEqual(0xFF, p0.b);
}

test "selection single line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 0, 2 }, &sels[1].?);
    try testing.expectEqual(null, sels[2]);

    // Clear the selection
    try screen.select(null);
    try state.update(alloc, &t);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqual(null, sels[1]);
    try testing.expectEqual(null, sels[2]);
}

test "selection multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, screen.pages.cols - 1 },
        &sels[1].?,
    );
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, 2 },
        &sels[2].?,
    );
}

test "selection starting on wide char spacer tail" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Wide char at x=1 with its spacer tail at x=2.
    s.nextSlice("a宽b");

    // Start on the spacer tail, as when selecting from the right.
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 1, 3 }, &sels[0].?);
    try testing.expectEqual(null, sels[1]);
}

test "selection ending on wide char spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: Terminal = try .init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // The wide char wraps, leaving a spacer head at x=9.
    // Position the cursor before rendering so overwriting the spacer
    // head won't dirty the following row through cursor movement.
    s.nextSlice("abcdefghi宽\x1b[1;10H");

    // Select up to and including the spacer head.
    const screen: *Screen = t.screens.active;
    const sel: Selection = .init(
        screen.pages.pin(.{ .active = .{ .x = 7, .y = 0 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 9, .y = 0 } }).?,
        false,
    );

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // A rectangle selection doesn't unwrap so it doesn't extend.
    try screen.select(.init(sel.start(), sel.end(), true));
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    const dirty = row_data.items(.dirty);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 7, 9 }, &sels[0].?);
    try testing.expectEqual(null, sels[1]);

    // A normal selection includes the wrapped wide char.
    try screen.select(sel);
    try state.update(alloc, &t);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 7, 9 }, &sels[0].?);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 0, 0 }, &sels[1].?);
    try testing.expectEqual(null, sels[2]);

    // Removing the spacer head must unselect and redraw the following row.
    state.clean();
    s.nextSlice("Z");
    try state.update(alloc, &t);
    try testing.expectEqual(null, sels[1]);
    try testing.expect(dirty[1]);
    try testing.expect(!dirty[2]);
}

test "linkCells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Create a hyperlink
    s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    try state.update(alloc, &t);

    // Query link at 0,0
    var cells = try state.linkCells(alloc, .{ .x = 0, .y = 0 });
    defer cells.deinit(alloc);

    try testing.expectEqual(4, cells.count());
    try testing.expect(cells.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 3, .y = 0 }));

    // Query no link
    var cells2 = try state.linkCells(alloc, .{ .x = 4, .y = 0 });
    defer cells2.deinit(alloc);
    try testing.expectEqual(0, cells2.count());
}

test "string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 5,
        .rows = 2,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("AB");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();

    try state.string(&w.writer, null);

    const result = try w.toOwnedSlice();
    defer alloc.free(result);

    const expected = "AB\x00\x00\x00\n\x00\x00\x00\x00\x00\n";
    try testing.expectEqualStrings(expected, result);
}

test "linkCells with scrollback spanning pages" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const viewport_rows: size.CellCountInt = 10;
    const tail_rows: size.CellCountInt = 5;

    var t = try Terminal.init(io, alloc, .{
        .cols = page.std_capacity.cols,
        .rows = viewport_rows,
        .max_scrollback_bytes = 10_000,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screens.active.pages;
    const first_page_cap = pages.pages.first.?.capacity().rows;

    // Fill first page
    for (0..first_page_cap - 1) |_| s.nextSlice("\r\n");

    // Create second page with hyperlink
    s.nextSlice("\r\n");
    s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    for (0..(tail_rows - 1)) |_| s.nextSlice("\r\n");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const expected_viewport_y: usize = viewport_rows - tail_rows;
    // BUG: This crashes without the fix
    var cells = try state.linkCells(alloc, .{
        .x = 0,
        .y = expected_viewport_y,
    });
    defer cells.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), cells.count());
}

test "linkCells with invalid viewport point" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Row out of bound
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = 0, .y = t.rows + 10 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }

    // Col out of bound
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = t.cols + 10, .y = 0 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }
}

test "flattened highlights require matching page serial" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    // Capture the live generation while terminal-owned state is in scope so
    // we can also verify beginUpdate copies it into the render row.
    const live_pin = t.screens.active.pages.getTopLeft(.viewport);
    const live_serial = live_pin.node.serial;

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const pin: PageList.Pin = pin: {
        const row_data = state.row_data.slice();
        @memset(row_data.items(.dirty), false);
        state.dirty = .false;
        break :pin row_data.items(.pin)[0];
    };
    const row_serial = state.row_data.items(.serial)[0];
    try testing.expectEqual(live_pin.node, pin.node);
    try testing.expectEqual(live_serial, row_serial);

    // Use the exact node pointer and row captured by the render state, but a
    // different generation. A reused node address must not make this stale
    // flattened highlight match.
    var hl: highlight.Flattened = .{
        .chunks = .empty,
        .top_x = 2,
        .bot_x = 4,
    };
    defer hl.deinit(alloc);
    try hl.chunks.append(alloc, .{
        .node = pin.node,
        .serial = live_serial ^ 1,
        .start = pin.y,
        .end = pin.y + 1,
    });

    try state.updateHighlightsFlattened(alloc, 42, &.{hl});
    {
        const row_data = state.row_data.slice();
        try testing.expectEqual(0, row_data.items(.highlights)[0].items.len);
        try testing.expect(!row_data.items(.dirty)[0]);
        try testing.expectEqual(.false, state.dirty);
    }

    // The same chunk is accepted once its copied serial also matches.
    hl.chunks.items(.serial)[0] = live_serial;
    try state.updateHighlightsFlattened(alloc, 42, &.{hl});
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights)[0].items;
        try testing.expectEqual(1, row_highlights.len);
        try testing.expectEqual(42, row_highlights[0].tag);
        try testing.expectEqual([2]size.CellCountInt{ 2, 4 }, row_highlights[0].range);
        try testing.expect(row_data.items(.dirty)[0]);
        try testing.expectEqual(.partial, state.dirty);
    }
}

test "dirty row resets highlights" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABC");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Reset dirty state
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }

    // Manually add a highlight to row 0
    {
        const row_data = state.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_highlights = row_data.items(.highlights);
        var arena = row_arenas[0].promote(alloc);
        defer row_arenas[0] = arena.state;
        try row_highlights[0].append(arena.allocator(), .{
            .tag = 1,
            .range = .{ 0, 2 },
        });
    }

    // Verify we have a highlight
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(1, row_highlights[0].items.len);
    }

    // Write to row 0 to make it dirty
    s.nextSlice("\x1b[H"); // Move to home
    s.nextSlice("X");
    try state.update(alloc, &t);

    // Verify the highlight was reset on the dirty row
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(0, row_highlights[0].items.len);
    }
}

/// Writes lines "0", "1", ... up to `n - 1` into the terminal, each
/// followed by a newline, so the cursor ends on an empty row below them.
fn testWriteNumberedLines(t: *Terminal, n: usize) !void {
    var s = t.vtStream();
    defer s.deinit();
    var buf: [32]u8 = undefined;
    for (0..n) |i| s.nextSlice(try std.mem.print(&buf, "{d}\r\n", .{i}));
}

/// Returns the number written on the row at `row_data` index `idx` by
/// testWriteNumberedLines, or null if the row is empty.
fn testRowNumber(state: *const RenderState, idx: usize) ?usize {
    const cells = state.row_data.items(.cells)[idx].items(.raw);
    var result: ?usize = null;
    for (cells) |cell| {
        const cp = cell.codepoint();
        if (cp < '0' or cp > '9') break;
        result = (result orelse 0) * 10 + (cp - '0');
    }
    return result;
}

test "overscan zero request unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    for ([_]bool{ false, true }) |scrolled| {
        if (scrolled) t.scrollViewport(.{ .delta = -5 });
        try state.update(alloc, &t);
        try testing.expectEqual(10, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(10, state.rowDataRange().end);
        try testing.expect(state.overscan.eql(.{}));
        try testing.expectEqual(0, state.viewportStart());
    }

    // Viewport row 0 is at index 0.
    try testing.expectEqual(36, testRowNumber(&state, 0).?);
}

test "overscan row_data layout" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);

    // Screen rows 0..49 hold "0".."49" and screen row 50 is the empty
    // cursor row. The active area (and bottom viewport) is 41..50.
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 3, .below = 2 };

    // Viewport follows the active area: nothing exists below.
    {
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 0 }));
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(13, state.rowDataRange().end);
        try testing.expectEqual(3, state.viewportStart());
        try testing.expectEqual(-3, state.viewportY(0));
        try testing.expectEqual(0, state.viewportY(3));

        // Viewport row 0 matches a state with no request.
        var plain: RenderState = .empty;
        defer plain.deinit(alloc);
        try plain.update(alloc, &t);
        const vp = state.viewportStart();
        for (0..state.rows) |y| {
            const a = state.row_data.get(vp + y);
            const b = plain.row_data.get(y);
            try testing.expectEqual(b.pin.node, a.pin.node);
            try testing.expectEqual(b.pin.y, a.pin.y);
            try testing.expectEqual(
                @as(page.Row.Backing, @bitCast(b.raw)),
                @as(page.Row.Backing, @bitCast(a.raw)),
            );
            for (b.cells.items(.raw), a.cells.items(.raw)) |bc, ac| {
                try testing.expectEqual(
                    @as(page.Cell.Backing, @bitCast(bc)),
                    @as(page.Cell.Backing, @bitCast(ac)),
                );
            }
        }
        try testing.expectEqual(41, testRowNumber(&state, vp).?);
        try testing.expectEqual(38, testRowNumber(&state, 0).?);
        try testing.expectEqual(40, testRowNumber(&state, vp - 1).?);
    }

    // Scrolled into history: both sides are fully captured.
    {
        t.scrollViewport(.{ .delta = -5 });
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 2 }));
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, state.rowDataRange().start);
        try testing.expectEqual(15, state.rowDataRange().end);

        const vp = state.viewportStart();
        try testing.expectEqual(36, testRowNumber(&state, vp).?);
        try testing.expectEqual(35, testRowNumber(&state, vp - 1).?);
        try testing.expectEqual(46, testRowNumber(&state, vp + state.rows).?);
        try testing.expectEqual(47, testRowNumber(&state, vp + state.rows + 1).?);
    }

    // At the top of history: nothing exists above.
    {
        t.scrollViewport(.top);
        try state.update(alloc, &t);
        try testing.expectEqual(0, state.overscan.above);
        try testing.expectEqual(2, state.overscan.below);
        try testing.expectEqual(state.viewportStart(), state.rowDataRange().start);
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, testRowNumber(&state, state.viewportStart()).?);

        t.scrollViewport(.{ .row = 1 });
        try state.update(alloc, &t);
        try testing.expectEqual(1, state.overscan.above);
        try testing.expectEqual(2, state.rowDataRange().start);
        try testing.expectEqual(15, state.row_data.len);
        try testing.expectEqual(0, testRowNumber(&state, 2).?);
        try testing.expectEqual(1, testRowNumber(&state, 3).?);
    }

    // Partially scrolled: fewer rows below than requested.
    {
        t.scrollViewport(.bottom);
        t.scrollViewport(.{ .delta = -1 });
        try state.update(alloc, &t);
        try testing.expect(state.overscan.eql(.{ .above = 3, .below = 1 }));
        try testing.expectEqual(14, state.rowDataRange().end);
        try testing.expectEqual(15, state.row_data.len);
    }
}

test "overscan request change forces redraw" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    state.clean();

    // No change is not dirty.
    try state.update(alloc, &t);
    try testing.expectEqual(.false, state.dirty);

    state.overscan_request = .{ .above = 4, .below = 1 };
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);
    try testing.expectEqual(15, state.row_data.len);
    try testing.expectEqual(4, state.viewportStart());
    try testing.expectEqual(41, testRowNumber(&state, 4).?);

    // And back to nothing.
    state.clean();
    state.overscan_request = .{};
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);
    try testing.expectEqual(10, state.row_data.len);
    try testing.expectEqual(41, testRowNumber(&state, 0).?);
}

test "overscan row ids stable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 3, .below = 2 };
    try state.update(alloc, &t);

    // Record all populated ids.
    const range = state.rowDataRange();
    try testing.expectEqual(0, range.start);
    try testing.expectEqual(13, range.end);
    var ids: [13]RenderState.Row.Id = undefined;
    for (&ids, range.start..) |*id, i| id.* = state.row_data.get(i).id();

    // Ids within one update are distinct.
    for (ids, 0..) |a, i| for (ids[i + 1 ..]) |b| {
        try testing.expect(!a.eql(b));
    };

    // Write a line while following the active area. Every row moves up
    // one index and the top row is no longer captured.
    try testWriteNumberedLines(&t, 1);
    try state.update(alloc, &t);
    try testing.expectEqual(13, state.rowDataRange().end);
    for (ids[1..], 0..) |id, i| {
        try testing.expect(id.eql(state.row_data.get(i).id()));
    }

    // Scroll up one row: the recorded ids are back at their original
    // indices, and one more row is captured below.
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(14, state.rowDataRange().end);
    for (ids, 0..) |id, i| {
        try testing.expect(id.eql(state.row_data.get(i).id()));
    }
}

test "overscan row ids and dirty on in-place rewrite" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Alternate screen has no scrollback, so scrolling a region rewrites
    // rows in place (eraseRowBounded) rather than moving the viewport.
    s.nextSlice("\x1b[?1049h");
    s.nextSlice("0\r\n1\r\n2\r\n3\r\n4");
    s.nextSlice("\x1b[2;5r\x1b[5;2H");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 2, .below = 2 };
    try state.update(alloc, &t);
    try testing.expect(state.overscan.eql(.{}));

    const vp = state.viewportStart();
    var ids: [5]RenderState.Row.Id = undefined;
    var nums: [5]?usize = undefined;
    for (&ids, &nums, vp..) |*id, *num, i| {
        id.* = state.row_data.get(i).id();
        num.* = testRowNumber(&state, i);
    }
    state.clean();

    // Scroll the region up one row.
    s.nextSlice("\r\n5");
    try state.update(alloc, &t);
    try testing.expect(state.dirty != .false);

    // The id contract: a row with an unchanged id and no dirty mark has
    // unchanged content, and every row whose content changed is dirty.
    for (ids, nums, vp..) |id, num, i| {
        const row = state.row_data.get(i);
        const new_num = testRowNumber(&state, i);
        try testing.expectEqual(if (i == vp) 0 else i - vp + 1, new_num.?);
        if (id.eql(row.id()) and !row.dirty) {
            try testing.expectEqual(num, new_num);
        }
        if (num != new_num) try testing.expect(row.dirty);
    }

    // At the time of writing, rotating rows in place invalidates the
    // page serial (PageList.invalidateNodeLayout), so no id survives.
    for (ids, vp..) |id, i| {
        try testing.expect(!id.eql(state.row_data.get(i).id()));
    }
}

test "overscan cursor in overscan row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);

    // The cursor is on the last active row.
    try testWriteNumberedLines(&t, 50);

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .below = 2 };

    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.below);
    try testing.expect(state.cursor.viewport == null);

    t.scrollViewport(.bottom);
    try state.update(alloc, &t);
    try testing.expectEqual(state.rows - 1, state.cursor.viewport.?.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
}

test "overscan selection on overscan rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback_bytes = 1_000_000,
    });
    defer t.deinit(alloc);
    try testWriteNumberedLines(&t, 50);

    // Select the last two active rows.
    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 8 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 9 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .below = 2 };

    // Scroll so the last active row is overscan-below.
    t.scrollViewport(.{ .delta = -1 });
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.below);

    const vp = state.viewportStart();
    const sels = state.row_data.items(.selection);
    try testing.expectEqual(
        [2]size.CellCountInt{ 0, 9 },
        sels[vp + state.rows - 1].?,
    );
    try testing.expectEqual(
        [2]size.CellCountInt{ 0, 2 },
        sels[vp + state.rows].?,
    );
    try testing.expect(sels[vp + state.rows - 2] == null);
}

test "placeholders: runs" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Run = struct {
        y: usize = 0,
        x: size.CellCountInt,
        width: size.CellCountInt,
        image_id: u32 = 0,
        placement_id: u32 = 0,
        row: u32 = 0,
        col: u32 = 0,
    };

    // Each case writes `input` to a new terminal and expects exactly
    // these placeholder runs, in order. No images exist, so none of them
    // have anything to draw.
    const cases: []const struct {
        input: []const u8,
        runs: []const Run,
    } = &.{
        // No placeholders.
        .{ .input = "hello\r\nworld\r\n1\r\n2", .runs = &.{} },

        // A single cell.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}",
            .runs = &.{.{ .x = 0, .width = 1 }},
        },

        // Two runs because the column jumps.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030E}",
            .runs = &.{
                .{ .x = 0, .width = 1 },
                .{ .x = 1, .width = 1, .col = 2 },
            },
        },

        // Explicit rows and columns that continue the run.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}" ++
                "\u{10EEEE}\u{0305}\u{030E}",
            .runs = &.{.{ .x = 0, .width = 3 }},
        },

        // Cells without a column continue the run.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{10EEEE}\u{0305}",
            .runs = &.{.{ .x = 0, .width = 3 }},
        },

        // Plain cells with no style or grapheme.
        .{
            .input = "\u{10EEEE}\u{10EEEE}\u{10EEEE}",
            .runs = &.{.{ .x = 0, .width = 3 }},
        },

        // Styled plain cells, which are found through their style run.
        .{
            .input = "\x1b[38;5;42mA\u{10EEEE}\u{0305}\u{030D}\u{10EEEE}" ++
                "\u{10EEEE}B\u{10EEEE}\u{10EEEE}",
            .runs = &.{
                .{ .x = 1, .width = 3, .image_id = 42, .col = 1 },
                .{ .x = 5, .width = 2, .image_id = 42 },
            },
        },

        // A run ends at a cell that isn't a placeholder.
        .{
            .input = "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}ABC",
            .runs = &.{.{ .x = 0, .width = 2 }},
        },

        // A run starting in the middle of the row.
        .{
            .input = "ABC\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{030D}",
            .runs = &.{.{ .x = 3, .width = 2 }},
        },

        // The image ID as a palette foreground color.
        .{
            .input = "\x1b[38;5;42m\u{10EEEE}\u{0305}\u{0305}",
            .runs = &.{.{ .x = 0, .width = 1, .image_id = 42 }},
        },

        // The third diacritic sets the high 8 bits of the image ID. A
        // cell without it continues the run, and a different one breaks
        // it.
        .{
            .input = "\x1b[38;5;42m\u{10EEEE}\u{0305}\u{0305}\u{030E}" ++
                "\u{10EEEE}\u{0305}\u{10EEEE}\u{0305}\u{030E}\u{0305}",
            .runs = &.{
                .{ .x = 0, .width = 2, .image_id = 42 | (2 << 24) },
                .{ .x = 2, .width = 1, .image_id = 42, .col = 2 },
            },
        },

        // The placement ID as the underline color. A different placement
        // ID breaks the run.
        .{
            .input = "\x1b[38;5;42m\x1b[58;5;21m\u{10EEEE}\u{0305}\u{0305}" ++
                "\u{10EEEE}\x1b[58;5;22m\u{10EEEE}",
            .runs = &.{
                .{ .x = 0, .width = 2, .image_id = 42, .placement_id = 21 },
                .{ .x = 2, .width = 1, .image_id = 42, .placement_id = 22 },
            },
        },

        // RGB colors for both IDs, across several rows.
        .{
            .input = "\x1b[38;2;1;2;3m\x1b[58;2;0;0;7m" ++
                "\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\r\nx\r\n" ++
                "\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}\u{10EEEE}",
            .runs = &.{
                .{ .y = 0, .x = 0, .width = 2, .image_id = 0x010203, .placement_id = 7 },
                .{ .y = 2, .x = 0, .width = 3, .image_id = 0x010203, .placement_id = 7, .row = 1 },
            },
        },
    };

    for (cases) |case| {
        var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
        defer t.deinit(alloc);
        t.modes.set(.grapheme_cluster, true);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(case.input);

        var state: RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var actual: std.ArrayList(Run) = .empty;
        defer actual.deinit(alloc);
        for (state.row_data.items(.placeholders), 0..) |runs, y| {
            for (runs.items) |run| try actual.append(alloc, .{
                .y = y,
                .x = run.x,
                .width = run.width,
                .image_id = run.image_id,
                .placement_id = run.placement_id,
                .row = run.row,
                .col = run.col,
            });
        }
        try testing.expectEqualSlices(Run, case.runs, actual.items);

        var it = state.imagePlacementIterator();
        try testing.expect(it.next() == null);
    }
}

test "placeholders: resolved virtual placements" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
        .columns = 2,
        .rows = 2,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    t.screens.active.cursorAbsolute(3, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}");
    t.screens.active.cursorAbsolute(3, 2);
    try t.printString("\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Each run draws half of the image, like the renderer would.
    var it = state.imagePlacementIterator();
    for (0..2) |y| {
        const p = it.next().?;
        try testing.expectEqual(RenderState.KittyPlacement.Kind.virtual, p.protocol.kitty.kind);
        try testing.expectEqual(1, p.image_id);
        try testing.expectEqual(1, p.protocol.kitty.placement_id);
        try testing.expectEqual(3, p.x);
        try testing.expectEqual(@as(i32, @intCast(y + 1)), p.y);
        try testing.expectEqual(2, p.cols);
        try testing.expectEqual(1, p.rows);
        try testing.expectEqual(20, p.width);
        try testing.expectEqual(10, p.height);
        try testing.expectEqual(0, p.source_x);
        try testing.expectEqual(@as(u32, @intCast(y * 5)), p.source_y);
        try testing.expectEqual(10, p.source_width);
        try testing.expectEqual(5, p.source_height);
        try testing.expectEqual(-1, p.z);
        try testing.expectEqual(RenderState.ImageLayer.below_text, p.layer);
        try testing.expectEqual(RenderState.ImageProtocol.kitty, std.meta.activeTag(p.protocol));
        try testing.expectEqual(
            t.screens.active.kitty_images.imageById(1).?.generation,
            p.image_generation,
        );
    }
    try testing.expect(it.next() == null);
}

test "placeholders: only dirty rows are resolved again" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
        .columns = 2,
        .rows = 2,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\r\n");
    try t.printString("\u{10EEEE}\u{030D}\u{0305}\u{10EEEE}");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Overwrite the geometry with a marker value, so we can tell when a
    // run is looked up again.
    const poison = 12345;
    const rows = state.row_data.items(.placeholders);
    for (rows[0..2]) |runs| {
        try testing.expectEqual(1, runs.items.len);
        try testing.expectEqual(RenderState.Placeholder.State.visible, runs.items[0].state);
        runs.items[0].geometry.width = poison;
    }

    // An update with no changes looks up nothing.
    try state.update(alloc, &t);
    try testing.expectEqual(poison, rows[0].items[0].geometry.width);
    try testing.expectEqual(poison, rows[1].items[0].geometry.width);

    // Only the dirty row is rebuilt and looked up again.
    t.screens.active.pages.pin(.{ .active = .{ .y = 1 } }).?.markDirty();
    try state.update(alloc, &t);
    try testing.expectEqual(poison, rows[0].items[0].geometry.width);
    try testing.expectEqual(20, rows[1].items[0].geometry.width);

    // A change to the image storage looks up every row again.
    t.screens.active.kitty_images.markMutated(io);
    try state.update(alloc, &t);
    try testing.expectEqual(20, rows[0].items[0].geometry.width);

    // So does a cell size change. With wider cells, the image is
    // centered in the placement grid.
    rows[0].items[0].geometry.width = poison;
    t.width_px = 200;
    try state.update(alloc, &t);
    try testing.expectEqual(20, rows[0].items[0].geometry.width);
    try testing.expectEqual(10, rows[0].items[0].geometry.offset_x);
}

test "placeholders: relative placement rooted at a virtual placement" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try Terminal.init(io, alloc, .{ .rows = 5, .cols = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
        .columns = 2,
        .rows = 2,
    });
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.setAttribute(.{ .@"256_underline_color" = 1 });

    // Placeholder cells at (3, 1) and (1, 2). Relative placements
    // attached to the virtual placement are positioned from the smallest
    // column and row, (1, 1), even though no cell is there.
    t.screens.active.cursorAbsolute(3, 1);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    t.screens.active.cursorAbsolute(1, 2);
    try t.printString("\u{10EEEE}\u{030D}\u{0305}");

    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 5,
    });

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var it = state.imagePlacementIterator();
    try testing.expectEqual(.virtual, it.next().?.protocol.kitty.kind);
    try testing.expectEqual(.virtual, it.next().?.protocol.kitty.kind);
    const child = it.next().?;
    try testing.expectEqual(RenderState.KittyPlacement.Kind.relative, child.protocol.kitty.kind);
    try testing.expectEqual(1, child.image_id);
    try testing.expectEqual(2, child.protocol.kitty.placement_id);
    try testing.expectEqual(RenderState.ImageLayer.above_text, child.layer);
    try testing.expectEqual(2, child.x);
    try testing.expectEqual(3, child.y);
    try testing.expectEqual(1, child.cols);
    try testing.expectEqual(1, child.rows);
    try testing.expectEqual(10, child.width);
    try testing.expectEqual(10, child.height);
    try testing.expectEqual(5, child.z);
    try testing.expect(it.next() == null);

    // A new placeholder cell further left moves the child, even
    // though the storage didn't change.
    t.screens.active.cursorAbsolute(0, 3);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try state.update(alloc, &t);
    it = state.imagePlacementIterator();
    for (0..3) |_| try testing.expectEqual(.virtual, it.next().?.protocol.kitty.kind);
    const moved = it.next().?;
    try testing.expectEqual(1, moved.x);
    try testing.expectEqual(3, moved.y);
    try testing.expect(it.next() == null);

    // Without placeholder cells in the viewport the child isn't drawn.
    t.eraseDisplay(.complete, false);
    try state.update(alloc, &t);
    it = state.imagePlacementIterator();
    try testing.expect(it.next() == null);
}
