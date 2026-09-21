--[[--
vertical_library_scroll.koplugin

Adds an opt-in "vertical scrolling library" mode to KOReader's built-in
file browser (a.k.a. "the library" / FileManager) — Kindle-device-style:

  * Swipe UP  -> next page (instead of swipe LEFT)
  * Swipe DOWN -> previous page (instead of swipe RIGHT)
  * A vertical scrollbar is shown floating over the right edge of the
    screen, its thumb showing your position in the library; tap/drag on
    it to jump straight to a page.
  * An up-arrow and a down-arrow sit above/below the scrollbar and do the
    same thing as swiping up/down.

It is off by default. Turn it on from:
    File browser -> (folder-icon tab) -> Settings -> "Vertical scrolling
    library" (last item in that list).

This started life as a KOReader user-patch (a single .lua file dropped in
patches/). It's now a proper plugin instead, specifically so the settings
menu entry goes through KOReader's own official extension point for this
-- FileManagerMenu:registerToMainMenu() / :addToMainMenu() -- the same
mechanism the stock CoverBrowser plugin uses for its own "Mosaic and
detailed list settings" entry, rather than a hand-wrapped copy of the
menu-building function. Everything else (the overlay widget, the swipe
remap) works the same way it did as a patch.

WORKS WITH OR WITHOUT SimpleUI (github.com/doctorhetfield-cmd/simpleui.koplugin)
---------------------------------------------------------------------------
This plugin only touches KOReader's *core* file browser (`FileChooser`,
`Menu`, `FileManager`) -- the same screen you get to from SimpleUI's own
"Browse files" / folder-navigation entry points, since SimpleUI itself
patches (wraps) those same core classes rather than replacing them.

Every low-level hook below is installed as a *wrap*: it saves whatever
function was previously installed (which may already be SimpleUI's or
CoverBrowser's own wrapped version) and calls through to it, so:
  - If SimpleUI (or CoverBrowser's Mosaic/List grid, which is stock and
    enabled by default) is installed, this plugin layers on top of it
    instead of fighting it for control.
  - If SimpleUI is NOT installed, everything below still works exactly
    the same, against plain stock KOReader.

This plugin deliberately does NOT touch SimpleUI's own home-screen "Flat
Library" grid module (a curated row/shelf on its dashboard) -- that is a
separate, independent rendering engine (engines/sui_book_grid.lua) that
would need its own dedicated integration. What this plugin controls is
the full-screen file/library browser itself.

TWO THINGS WORTH KNOWING ABOUT THE IMPLEMENTATION
---------------------------------------------------------------------------
1. The book grid/list is actually narrowed (real layout space is
   reserved on the right) so the scrollbar overlay never sits on top of
   a cover or filename -- see the _recalculateDimen wrap in section 1/2
   below.
2. When SimpleUI is installed, it replaces KOReader's stock
   "filemanager_swipe" touch zone with its own, which -- by SimpleUI's
   own design -- does NOT forward north/south (vertical) swipes to
   onSwipeFM at all (it lets them fall through to open SimpleUI's top
   menu instead). That means just wrapping onSwipeFM (which is all the
   previous version of this plugin did) is silently never reached for
   vertical swipes when SimpleUI is active. The fix is to register our
   own touch zone that explicitly overrides "filemanager_swipe" -- see
   section 4 below for the full explanation.

INSTALL
---------------------------------------------------------------------------
Copy the WHOLE `vertical_library_scroll.koplugin` FOLDER (not just this
file) into KOReader's `plugins/` folder, next to `simpleui.koplugin`:

    koreader/plugins/vertical_library_scroll.koplugin/

Then restart KOReader. It's enabled by default (like any new plugin) --
no separate "enable plugin" step needed, though you can confirm it shows
up unchecked as disabled under Plugin management if you want to double
check it was found.

Everything here is written defensively (pcall-guarded) so that if a
future KOReader update renames/removes something this plugin depends on,
it will log a warning and simply not enable the feature, rather than
breaking your file browser.
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local SETTING_KEY = "vertical_library_scroll"

local function isEnabled()
    return G_reader_settings:isTrue(SETTING_KEY)
end

--=============================================================================
-- Low-level hooks into KOReader core (FileChooser / Menu / FileManager).
-- Installed once, at module load time (mirrors how the stock CoverBrowser
-- plugin does its own core-class patching -- see its main.lua comment:
-- "saving them as attributes in init() does not allow us to get back to
-- classic mode" -- i.e. this belongs at module scope, not inside :init()).
--=============================================================================

local ok_guard, FileChooser = pcall(require, "ui/widget/filechooser")

if ok_guard and FileChooser and not FileChooser._vlibscroll_patch_installed then
    FileChooser._vlibscroll_patch_installed = true

    local BD = require("ui/bidi")
    local Button = require("ui/widget/button")
    local Device = require("device")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Menu = require("ui/widget/menu")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalScrollBar = require("ui/widget/verticalscrollbar")
    local VerticalSpan = require("ui/widget/verticalspan")
    local logger = require("logger")
    local Screen = Device.screen

    -----------------------------------------------------------------------
    -- 1. The floating overlay widget: up-arrow / scrollbar / down-arrow,
    --    anchored to the right edge (left edge in mirrored/RTL layouts)
    --    of the file browser, spanning the item list's vertical extent.
    --
    --    buildArrowButtons()/assembleOverlayFrame() are split out of what
    --    used to be a single buildOverlay() function so that the WIDTH
    --    the overlay needs can be measured once (getReservedWidth(),
    --    below) using a disposable throwaway frame, cheaply, without
    --    needing fc to be init()'d yet -- the frame's width only depends
    --    on fixed, screen-scale-based constants (button/scrollbar sizes),
    --    never on fc.inner_dimen or the real track height. That measured
    --    width is what the _recalculateDimen wrap (section 2) subtracts
    --    from the item grid's available width, so covers/rows are laid
    --    out narrower and leave a real gutter -- rather than the overlay
    --    just floating on top of them with no space reserved.
    -----------------------------------------------------------------------

    local function buildArrowButtons(fc)
        local margin = Screen:scaleBySize(6)
        -- Visual width of the scrollbar TRACK itself (VerticalScrollBar's
        -- :getSize().w is exactly this value -- see
        -- frontend/ui/widget/verticalscrollbar.lua). Deliberately kept
        -- thin (stock KOReader's own default is Size.padding.default,
        -- Screen:scaleBySize(5)); the scrollbar's *touchable* hit area is
        -- separately widened well beyond this by its own
        -- extra_touch_on_side_width_ratio, so a thin visual track doesn't
        -- make it harder to grab -- it just looks less heavy.
        local bar_w = Screen:scaleBySize(8)
        local icon_size = Screen:scaleBySize(20)
        local span_h = Screen:scaleBySize(8)

        local function arrowButton(rotate, callback)
            return Button:new{
                icon = "chevron.up",
                icon_rotation_angle = rotate,
                icon_width = icon_size,
                icon_height = icon_size,
                bordersize = 0,
                padding = Screen:scaleBySize(6),
                show_parent = fc.show_parent,
                callback = callback,
            }
        end

        local up_btn = arrowButton(0, function() fc:onPrevPage() end)
        local down_btn = arrowButton(180, function() fc:onNextPage() end)

        return up_btn, down_btn, margin, bar_w, span_h
    end

    local function assembleOverlayFrame(fc, up_btn, down_btn, track_h, bar_w, margin, span_h)
        local scrollbar = VerticalScrollBar:new{
            width = bar_w,
            height = track_h,
            scroll_callback = function(ratio)
                local page_num = fc.page_num or 1
                if page_num <= 1 then return end
                local target = math.floor(ratio * page_num) + 1
                if target < 1 then target = 1 end
                if target > page_num then target = page_num end
                fc:onGotoPage(target)
            end,
        }

        local inner = VerticalGroup:new{
            align = "center",
            up_btn,
            VerticalSpan:new{ width = span_h },
            scrollbar,
            VerticalSpan:new{ width = span_h },
            down_btn,
        }

        -- No visible border/background/rounded-corner box around the
        -- arrows+scrollbar -- just a zero-padding passthrough container,
        -- kept only so buildOverlay()/getReservedWidth() have a single
        -- widget to measure and position. They float directly over the
        -- book grid, with nothing drawn behind or around them.
        local frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            inner,
        }

        return frame, scrollbar
    end

    -- Cached after the first successful measurement: the reserved width
    -- only depends on Screen:scaleBySize()/Size.border.thin, which don't
    -- change over a running session (rotation swaps w/h, not DPI scale).
    local cached_reserved_w = nil
    local function getReservedWidth(fc)
        if cached_reserved_w then return cached_reserved_w end
        local ok, w = pcall(function()
            local up_btn, down_btn, margin, bar_w, span_h = buildArrowButtons(fc)
            -- Placeholder track height: doesn't affect the frame's WIDTH,
            -- only its height, and we only read :getSize().w below.
            local frame = assembleOverlayFrame(fc, up_btn, down_btn, Screen:scaleBySize(60), bar_w, margin, span_h)
            return frame:getSize().w + margin
        end)
        if ok and w and w > 0 then
            cached_reserved_w = w
            return w
        end
        return 0
    end

    -- Applies the current page/page_num state of `menu_self` (a
    -- FileChooser instance we've decorated) to our overlay widgets, and
    -- forces the stock horizontal pager (chevrons + "Page X of Y") to
    -- stay hidden & inert. Safe to call repeatedly; safe to call even if
    -- some stock widgets were nil'd out by another plugin (e.g.
    -- SimpleUI's navbar feature).
    local function syncOverlayState(menu_self)
        if not menu_self._vlibscroll_bar then return end
        local ok, err = pcall(function()
            local page = menu_self.page or 1
            local page_num = menu_self.page_num or 1

            if page_num > 1 then
                menu_self._vlibscroll_bar.enable = true
                menu_self._vlibscroll_bar:set((page - 1) / page_num, page / page_num)
                menu_self._vlibscroll_up:enableDisable(page > 1)
                menu_self._vlibscroll_down:enableDisable(page < page_num)
            else
                menu_self._vlibscroll_bar.enable = false
                menu_self._vlibscroll_up:enableDisable(false)
                menu_self._vlibscroll_down:enableDisable(false)
            end

            for _, w in ipairs{
                menu_self.page_info_left_chev,
                menu_self.page_info_right_chev,
                menu_self.page_info_first_chev,
                menu_self.page_info_last_chev,
                menu_self.page_info_text,
            } do
                if w then
                    if w.hide then w:hide() end
                    if w.disable then w:disable() end
                end
            end
        end)
        if not ok then
            logger.warn("vertical_library_scroll: syncOverlayState failed:", err)
        end
    end

    -- Builds the [up-arrow / scrollbar / down-arrow] overlay and appends
    -- it to `fc`'s own widget tree (fc[1][1] is the OverlapGroup
    -- Menu:init() builds to stack the item list, the "go up" return
    -- arrow and the footer pager on top of each other -- appending here
    -- makes our overlay paint on top of all of those, i.e. floating
    -- above the book grid/list).
    local function buildOverlay(fc)
        local top_height = (fc.title_bar and not fc.no_title) and fc.title_bar:getHeight() or 0
        local avail_h = fc.available_height or (fc.inner_dimen.h - top_height)
        if avail_h <= 0 then return end

        local up_btn, down_btn, margin, bar_w, span_h = buildArrowButtons(fc)

        local reserved = up_btn:getSize().h + down_btn:getSize().h + 2 * span_h + 2 * margin
        local track_h = avail_h - reserved
        local min_track_h = Screen:scaleBySize(60)
        if track_h < min_track_h then
            track_h = math.min(min_track_h, avail_h > 0 and avail_h or min_track_h)
        end

        local frame, scrollbar = assembleOverlayFrame(fc, up_btn, down_btn, track_h, bar_w, margin, span_h)

        local size = frame:getSize()
        local x
        if BD.mirroredUILayout() then
            x = margin
        else
            x = fc.inner_dimen.w - size.w - margin
        end
        local y = top_height + math.max(margin, math.floor((avail_h - size.h) / 2))
        frame.overlap_offset = { x, y }

        fc._vlibscroll_frame = frame
        fc._vlibscroll_bar = scrollbar
        fc._vlibscroll_up = up_btn
        fc._vlibscroll_down = down_btn

        table.insert(fc[1][1], frame)

        syncOverlayState(fc)
    end

    -----------------------------------------------------------------------
    -- 2. Hook FileChooser:init() -- two things happen here, in order:
    --
    --    a) BEFORE calling through to the stock (possibly
    --       already-patched-by-someone-else) init, install an
    --       instance-level override of self:_recalculateDimen() that
    --       temporarily shrinks self.inner_dimen.w by the overlay's
    --       measured width for the duration of that one call, then
    --       restores it. _recalculateDimen is what Mosaic/List/classic
    --       mode all use to compute item/row width from inner_dimen.w
    --       (self:_recalculateDimen() is always called via ":", i.e.
    --       dynamic method dispatch -- so an instance-level override
    --       here really does take priority over whatever class-level
    --       implementation CoverBrowser has installed for the current
    --       display mode, without us having to know or care which mode
    --       that is). The net effect: covers/rows are laid out narrower
    --       from the start, leaving a real gutter on the right for the
    --       overlay -- instead of the overlay floating on top of them.
    --
    --       This has to happen *before* orig_fc_init runs, since that's
    --       what triggers the first _recalculateDimen() call.
    --
    --    b) AFTER orig_fc_init has finished setting up the title bar /
    --       footer / item list, build and position the actual overlay,
    --       same as before -- and only for the real file-manager/library
    --       screen (self.name == "filemanager"), not other FileChooser
    --       popups.
    -----------------------------------------------------------------------

    local orig_fc_init = FileChooser.init
    FileChooser.init = function(self, ...)
        if self.name == "filemanager" and isEnabled() then
            local reserved = getReservedWidth(self)
            if reserved > 0 and not self._vlibscroll_recalc_installed then
                self._vlibscroll_recalc_installed = true
                local orig_recalc = self._recalculateDimen
                self._recalculateDimen = function(inst, ...)
                    local dimen = inst.inner_dimen
                    local true_w = dimen and dimen.w
                    if dimen and true_w and isEnabled() then
                        dimen.w = true_w - reserved
                    end
                    local ok, err = pcall(orig_recalc, inst, ...)
                    if dimen and true_w then
                        dimen.w = true_w
                    end
                    if not ok then
                        logger.warn("vertical_library_scroll: _recalculateDimen failed:", err)
                    end
                end
            end
        end

        orig_fc_init(self, ...)

        if self.name == "filemanager" and isEnabled() then
            local ok, err = pcall(buildOverlay, self)
            if not ok then
                logger.warn("vertical_library_scroll: buildOverlay failed:", err)
            end
        end
    end

    -----------------------------------------------------------------------
    -- 3. Hook Menu:updatePageInfo() -- called every time the
    --    page/selection changes (page turn, refresh, etc). Piggyback on
    --    it to keep the scrollbar thumb and arrow enabled/disabled state
    --    in sync, and to keep re-hiding the stock footer pager (it
    --    re-shows itself here on every call, so ours must run after,
    --    every time too).
    -----------------------------------------------------------------------

    local orig_updatePageInfo = Menu.updatePageInfo
    Menu.updatePageInfo = function(self, select_number)
        orig_updatePageInfo(self, select_number)
        if self._vlibscroll_bar then
            syncOverlayState(self)
        end
    end

    -----------------------------------------------------------------------
    -- 4. Make swipes actually turn pages.
    --
    --    4a) Wrap FileManager:onSwipeFM() -- this is where stock KOReader
    --        decides what a swipe does in the file manager (Menu:onSwipe()
    --        is *not* used for the top-level file manager -- it delegates
    --        to GestureManager/touch zones instead, see menu.lua). Kept
    --        as a belt-and-braces remap of swipe-up/down to next/prev
    --        page (and swallowing swipe-left/right) for anything that
    --        calls onSwipeFM directly.
    --
    --    4b) THE ACTUAL FIX for "no gesture works": register our own
    --        touch zone that runs *before* "filemanager_swipe".
    --
    --        Why 4a alone is not enough: stock KOReader registers a
    --        full-screen "filemanager_swipe" touch zone (in
    --        FileManager:initGesListener()) whose handler calls
    --        self:onSwipeFM(ges) for every swipe direction -- so 4a on
    --        its own is enough with plain stock KOReader. But SimpleUI
    --        (infra/sui_patches.lua, patchFileManagerClass) *replaces*
    --        that same zone id with its own handler, which explicitly
    --        does NOT call onSwipeFM for north/south (vertical) swipes:
    --        it returns false for those on purpose, so the swipe falls
    --        through to FileManagerMenu's top-of-screen zones and opens
    --        SimpleUI's menu instead. That's a deliberate SimpleUI
    --        design choice for its own navigation, but it means our 4a
    --        wrap is simply never reached for vertical swipes once
    --        SimpleUI is installed -- no matter what it does internally.
    --
    --        The fix is to register a zone of our own, under a
    --        different id, that `overrides` (i.e. is checked before)
    --        "filemanager_swipe" -- whichever version of it currently
    --        exists, stock's or SimpleUI's. KOReader's touch-zone
    --        override graph (DepGraph, in registerTouchZones) resolves
    --        purely by id and tolerates forward references, so this
    --        works regardless of plugin load order. When our mode is
    --        off, or the swipe isn't north/south, our handler returns
    --        false and dispatch falls through to "filemanager_swipe"
    --        exactly as if we weren't here -- so this can't break
    --        horizontal paging, menu-opening swipes, or anything else
    --        when vertical mode is disabled.
    -----------------------------------------------------------------------

    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager then
        -- 4a.
        local orig_onSwipeFM = FileManager.onSwipeFM
        FileManager.onSwipeFM = function(self, ges)
            local fc = self.file_chooser
            if fc and fc._vlibscroll_bar and isEnabled() then
                local ok, handled = pcall(function()
                    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
                    if direction == "north" then
                        fc:onNextPage()
                        return true
                    elseif direction == "south" then
                        fc:onPrevPage()
                        return true
                    elseif direction == "west" or direction == "east" then
                        -- Vertical mode replaces horizontal paging: swallow it.
                        return true
                    end
                    return false
                end)
                if ok and handled then
                    return true
                end
            end
            return orig_onSwipeFM(self, ges)
        end

        -- 4b.
        local orig_initGesListener = FileManager.initGesListener
        FileManager.initGesListener = function(self, ...)
            orig_initGesListener(self, ...)
            local ok, err = pcall(function()
                self:registerTouchZones({
                    {
                        id = "vertical_library_scroll_swipe",
                        ges = "swipe",
                        screen_zone = {
                            ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
                        },
                        overrides = { "filemanager_swipe" },
                        handler = function(ges)
                            local fc = self.file_chooser
                            if not (fc and fc._vlibscroll_bar and isEnabled()) then
                                return false
                            end
                            local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
                            if direction == "north" then
                                fc:onNextPage()
                                return true
                            elseif direction == "south" then
                                fc:onPrevPage()
                                return true
                            elseif direction == "west" or direction == "east" then
                                -- Vertical mode replaces horizontal paging: swallow it.
                                return true
                            end
                            return false
                        end,
                    },
                })
            end)
            if not ok then
                logger.warn("vertical_library_scroll: registering swipe zone failed:", err)
            end
        end
    end

    logger.info("vertical_library_scroll: core hooks installed")
end

--=============================================================================
-- 5. The plugin itself -- this is what actually gets the settings menu
--    entry to appear, through KOReader's official extension point:
--    FileManagerMenu:registerToMainMenu(self) + self:addToMainMenu(...).
--    This is the exact same mechanism the stock CoverBrowser plugin uses
--    for its own "Mosaic and detailed list settings" entry (see
--    plugins/coverbrowser.koplugin/main.lua), which is why this should
--    be considerably more reliable than the equivalent hand-wrapped code
--    in the previous patch-file version of this feature.
--=============================================================================

local VerticalLibraryScroll = WidgetContainer:extend{
    name = "vertical_library_scroll",
}

function VerticalLibraryScroll:init()
    if self.ui.document then
        -- Reader screen (ReaderUI): this feature is file-browser only.
        return
    end
    self.ui.menu:registerToMainMenu(self)
end

function VerticalLibraryScroll:addToMainMenu(menu_items)
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")

    local menu_item = {
        text = _("Vertical scrolling library"),
        help_text = _("Browse the library as vertically scrolling pages instead of horizontal swipe/arrows: swipe up/down to turn pages, or use the scrollbar and arrows on the right edge of the screen."),
        checked_func = function()
            return G_reader_settings:isTrue(SETTING_KEY)
        end,
        callback = function()
            G_reader_settings:flipNilOrFalse(SETTING_KEY)
            if FileManager.instance then
                UIManager:nextTick(function()
                    if FileManager.instance then
                        FileManager.instance:reinit()
                    end
                end)
            end
        end,
    }

    -- Primary spot: appended into the nested "Settings" submenu (the one
    -- with "Show hidden files" etc.) -- same array CoverBrowser appends
    -- its own display-mode-related settings into.
    local fbs = menu_items.filebrowser_settings
    if fbs and fbs.sub_item_table then
        menu_item.separator = true
        table.insert(fbs.sub_item_table, menu_item)
    else
        -- Fallback: surface it as its own top-level entry rather than
        -- silently dropping it if some other plugin has replaced
        -- filebrowser_settings entirely.
        menu_items[SETTING_KEY] = menu_item
    end
end

return VerticalLibraryScroll
