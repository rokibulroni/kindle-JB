local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local FFIUtil = require("ffi/util")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local zstd = require("ffi/zstd")
local time = require("ui/time")
local _ = require("l10n.gettext")
local N_ = _.ngettext
local T = FFIUtil.template
local ptdbg = require("ptdbg")

-- Database definition
local BOOKINFO_DB_VERSION = 20201210
local BOOKINFO_DB_SCHEMA = [[
    -- To cache book cover and metadata
    CREATE TABLE IF NOT EXISTS bookinfo (
        -- Internal book cache id
        -- (not to be used to identify a book, it may change)
        bcid                INTEGER PRIMARY KEY AUTOINCREMENT,

        -- File location and filename
        directory           TEXT NOT NULL, -- split by dir/name so we can get all files in a directory
        filename            TEXT NOT NULL, -- and can implement pruning of deleted files
        filesize            INTEGER,       -- size in bytes at most recent extraction time
        filemtime           INTEGER,       -- mtime at most recent extraction time

        -- Extraction status and result
        in_progress         INTEGER,  -- 0 (done), >0 : nb of tries (to avoid retrying failed extractions forever)
        unsupported         TEXT,     -- NULL if supported / reason for being unsupported
        cover_fetched       TEXT,     -- NULL / 'Y' = we tried to fetch a cover (but we may not have gotten one)
        has_meta            TEXT,     -- NULL / 'Y' = has metadata (title, authors...)
        has_cover           TEXT,     -- NULL / 'Y' = has cover image (cover_*)
        cover_sizetag       TEXT,     -- '1072x1448' (example, is the original cover image width and height)

        -- Other properties that can be set and returned as is (not used here)
        -- If user doesn't want to see these (wrong metadata, offending cover...)
        ignore_meta         TEXT,     -- NULL / 'Y' = ignore these metadata
        ignore_cover        TEXT,     -- NULL / 'Y' = ignore this cover

        -- Book info
        pages               INTEGER,

        -- Metadata (only these are returned by the engines)
        title               TEXT,
        authors             TEXT,
        series              TEXT,
        series_index        REAL,
        language            TEXT,
        keywords            TEXT,
        description         TEXT,

        -- Cover image
        cover_w             INTEGER,  -- blitbuffer width
        cover_h             INTEGER,  -- blitbuffer height
        cover_bb_type       INTEGER,  -- blitbuffer type (internal)
        cover_bb_stride     INTEGER,  -- blitbuffer stride (internal)
        cover_bb_data       BLOB      -- blitbuffer data compressed with zstd
    );
    CREATE UNIQUE INDEX IF NOT EXISTS dir_filename ON bookinfo(directory, filename);

    -- To keep track of CoverBrowser settings
    CREATE TABLE IF NOT EXISTS config (
        key TEXT PRIMARY KEY,
        value TEXT
    );
]]

local BOOKINFO_COLS_SET = {
    "directory",
    "filename",
    "filesize",
    "filemtime",
    "in_progress",
    "unsupported",
    "cover_fetched",
    "has_meta",
    "has_cover",
    "cover_sizetag",
    "ignore_meta",
    "ignore_cover",
    "pages", -- 13: start index for getDocProps()
    "title",
    "authors",
    "series",
    "series_index",
    "language",
    "keywords",
    "description", -- 20: end index for getDocProps()
    "cover_w",
    "cover_h",
    "cover_bb_type",
    "cover_bb_stride",
    "cover_bb_data",
}

local bookinfo_values_sql = {} -- for "VALUES (?, ?, ?,...)" insert sql part
for i = 1, #BOOKINFO_COLS_SET do
    table.insert(bookinfo_values_sql, "?")
end

local max_cover_dimen = 600 -- tested 400, 600, and 800

-- Build our most often used SQL queries according to columns
local BOOKINFO_INSERT_SQL = "INSERT OR REPLACE INTO bookinfo " ..
    "(" .. table.concat(BOOKINFO_COLS_SET, ",") .. ") " ..
    "VALUES (" .. table.concat(bookinfo_values_sql, ",") .. ");"
local BOOKINFO_SELECT_SQL = "SELECT " .. table.concat(BOOKINFO_COLS_SET, ",") .. " FROM bookinfo " ..
    "WHERE directory=? AND filename=? AND in_progress=0;"
local BOOKINFO_IN_PROGRESS_SQL =
"SELECT in_progress, filename, unsupported FROM bookinfo WHERE directory=? AND filename=?;"

-- We need these _ litterals for them to be made available to translators. the english "string" is
-- what is inserted in the DB, and it will be translated only when read from the DB and displayed.
local UNSUPPORTED_REASONS = {
    not_readable_by_engine = {
        string = "not readable by engine",
        translation = _("not readable by engine")
    },
    too_many_interruptions_or_crashes = {
        string = "too many interruptions or crashes",
        translation = _("too many interruptions or crashes")
    }
}

local BookInfoManager = {}

function BookInfoManager:init()
    self.db_location = DataStorage:getSettingsDir() .. "/PT_bookinfo_cache.sqlite3"
    self.db_created = false
    self.db_conn = nil
    self.max_extract_tries = 3              -- don't try more than that to extract info from a same book
    self.subprocesses_collector = nil
    self.subprocesses_collect_interval = 10 -- do that every 10 seconds
    self.subprocesses_pids = {}
    self.subprocesses_last_added_time = 0
    self.subprocesses_killall_timeout_time = time.s(300) -- cleanup timeout for stuck subprocesses
    -- 300 seconds should be more than enough to open and get info from 9-10 books
    -- Whether to use former blitbuffer:scale() (default to using MuPDF)
    self.use_legacy_image_scaling = G_reader_settings:isTrue("legacy_image_scaling")
    -- We will use a temporary directory for crengine cache while indexing
    self.tmpcr3cache = DataStorage:getDataDir() .. "/cache/tmpcr3cache"
end

-- DB management
function BookInfoManager:getDbSize()
    local file_size = lfs.attributes(self.db_location, "size") or 0
    local friendly_file_size = util.getFriendlySize(file_size)
    local num_books = "0"
    self:openDbConnection()
    local res = self.db_conn:exec("SELECT count(bcid) FROM bookinfo;")
    if res then
        num_books = string.match(tostring(res[1][1]), "^(%d+)")
    end
    return friendly_file_size .. "  —  " .. num_books .. " " .. _("Books")
end

function BookInfoManager:createDB()
    local db_conn = SQ3.open(self.db_location)
    -- Make it WAL, if possible
    if Device:canUseWAL() then
        db_conn:exec("PRAGMA journal_mode=WAL;")
    else
        db_conn:exec("PRAGMA journal_mode=TRUNCATE;")
    end
    -- Less error cases to check if we do it that way
    -- Create it (noop if already there)
    db_conn:exec(BOOKINFO_DB_SCHEMA)
    db_conn:exec(string.format("PRAGMA user_version=%d;", BOOKINFO_DB_VERSION))

    -- destroying the entire db is way too expensive, we will never do this
    -- look into using ALTER statements to modify the tables in-place
    -- local db_version = tonumber(db_conn:rowexec("PRAGMA user_version;"))
    -- if db_version < BOOKINFO_DB_VERSION then
    --     logger.warn(ptdbg.logprefix, "BookInfo cache DB schema updated from version", db_version, "to version", BOOKINFO_DB_VERSION)
    --     logger.warn(ptdbg.logprefix, "Deleting existing", self.db_location, "to recreate it")

    --     -- We'll try to preserve settings, though
    --     self:loadSettings(db_conn)

    --     db_conn:close()
    --     os.remove(self.db_location)

    --     -- Re-create it
    --     db_conn = SQ3.open(self.db_location)
    --     db_conn:exec(BOOKINFO_DB_SCHEMA)

    --     -- Restore non-deprecated settings
    --     for k, v in pairs(self.settings) do
    --         if k ~= "version" then
    --             self:saveSetting(k, v, db_conn, true)
    --         end
    --     end
    --     self:loadSettings(db_conn)

    --     -- Update version
    --     db_conn:exec(string.format("PRAGMA user_version=%d;", BOOKINFO_DB_VERSION))

    --     -- Say hi!
    --     UIManager:show(InfoMessage:new { text = _("Book info cache database updated."), timeout = 3 })
    -- end

    db_conn:close()
    self.db_created = true
end

function BookInfoManager:openDbConnection()
    if self.db_conn then
        return
    end
    if not self.db_created then
        self:createDB()
    end
    self.db_conn = SQ3.open(self.db_location)
    self.db_conn:set_busy_timeout(5000) -- 5 seconds

    -- Prepare our most often used SQL statements
    self.set_stmt = self.db_conn:prepare(BOOKINFO_INSERT_SQL)
    self.get_stmt = self.db_conn:prepare(BOOKINFO_SELECT_SQL)
    self.in_progress_stmt = self.db_conn:prepare(BOOKINFO_IN_PROGRESS_SQL)
end

function BookInfoManager:closeDbConnection()
    if self.db_conn then
        self.db_conn:close()
        self.db_conn = nil
    end
end

function BookInfoManager:deleteDb()
    self:openDbConnection()
    local query = "DELETE FROM bookinfo;"
    local stmt = self.db_conn:prepare(query)
    stmt:step()              -- commited
    stmt:clearbind():reset() -- cleanup
end

function BookInfoManager:compactDb()
    -- Reduce db size (note: "when VACUUMing a database, as much as twice the
    -- size of the original database file is required in free disk space")
    -- By default, sqlite will use a temporary file in /tmp/ . On Kobo, /tmp/
    -- is 16 Mb, and this will crash if DB is > 16Mb. For now, it's safer to
    -- use memory for temp files (which will also cause a crash when DB size
    -- is bigger than available memory...)
    local prev_size = self:getDbSize()
    self:openDbConnection()
    self.db_conn:exec("PRAGMA temp_store = 2;") -- use memory for temp files
    -- self.db_conn:exec("VACUUM")
    -- Catch possible "memory or disk is full" error
    local ok, errmsg = pcall(self.db_conn.exec, self.db_conn, "VACUUM;") -- this may take some time
    self:closeDbConnection()
    if not ok then
        return T(_("Failed compacting database: %1"), errmsg)
    end
    local cur_size = self:getDbSize()
    return T(_("Cache database size reduced from %1 to %2."), prev_size, cur_size)
end

-- Settings management, stored in 'config' table
function BookInfoManager:loadSettings(db_conn)
    if lfs.attributes(self.db_location, "mode") ~= "file" then
        -- no db, empty config
        self.settings = {}
        return
    end
    self.settings = {}

    local my_db_conn
    if db_conn then
        my_db_conn = db_conn
    else
        self:openDbConnection()
        my_db_conn = self.db_conn
    end

    local res = my_db_conn:exec("SELECT key, value FROM config;")
    if res then
        local keys = res[1]
        local values = res[2]
        for i, key in ipairs(keys) do
            self.settings[key] = tonumber(values[i]) or values[i] -- TEXT db field
        end
    end
end

function BookInfoManager:getSetting(key)
    if not self.settings then
        self:loadSettings()
    end
    return self.settings[key]
end

function BookInfoManager:saveSetting(key, value, db_conn, skip_reload)
    if not value or value == false or value == "" then
        if lfs.attributes(self.db_location, "mode") ~= "file" then
            -- If no db created, no need to save (and create db) an empty value
            return
        end
    end

    local my_db_conn
    if db_conn then
        my_db_conn = db_conn
    else
        self:openDbConnection()
        my_db_conn = self.db_conn
    end

    local query = "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?);"
    local stmt = my_db_conn:prepare(query)
    if value == false then    -- convert false to NULL
        value = nil
    elseif value == true then -- convert true to "Y"
        value = "Y"
    end
    stmt:bind(key, value)
    stmt:step()              -- commited
    stmt:clearbind():reset() -- cleanup

    -- Optionally, reload settings, so we may get (or not if it failed) what we just saved
    if not skip_reload then
        self:loadSettings()
    end
end

function BookInfoManager:toggleSetting(key)
    local value = not self:getSetting(key)
    self:saveSetting(key, value)
    return value
end

-- Bookinfo management
function BookInfoManager:getBookInfo(filepath, get_cover)
    local directory, filename = util.splitFilePathName(filepath)

    -- CoverBrowser may be used by PathChooser, which will not filter out
    -- files with unknown book extension. If not a supported extension,
    -- returns a bookinfo like-object enough for a correct display and
    -- to not trigger extraction, so we don't clutter DB with such files.
    local is_directory = lfs.attributes(filepath, "mode") == "directory"
    if is_directory or not DocumentRegistry:hasProvider(filepath) then
        return {
            directory = directory,
            filename = filename,
            --[[
            filesize = lfs.attributes(filepath, "size"),
            filemtime = lfs.attributes(filepath, "modification"),
            --]]
            in_progress = 0,
            cover_fetched = "Y",
            has_meta = nil,
            has_cover = nil,
            ignore_meta = "Y",
            ignore_cover = "Y",
            -- for CoverMenu to *not* extend the onHold dialog:
            _is_directory = is_directory,
            -- for ListMenu to show the filename *with* suffix:
            _no_provider = true
        }
    end

    self:openDbConnection()
    local row = self.get_stmt:bind(directory, filename):step()
    -- NOTE: We do not reset right now because we'll be querying a BLOB,
    --       so we need the data it points to to still be there ;).

    if not row then                       -- filepath not in db
        self.get_stmt:clearbind():reset() -- get ready for next query
        return nil
    end

    local bookinfo = {}
    for num, col in ipairs(BOOKINFO_COLS_SET) do
        if col == "pages" then
            -- See http://scilua.org/ljsqlite3.html "SQLite Type Mappings"
            bookinfo[col] = tonumber(row[num]) -- convert cdata<int64_t> to lua number
        else
            bookinfo[col] = row[num]           -- as is
        end
        -- specific processing for cover columns
        if col == "cover_w" then
            bookinfo["cover_w"] = tonumber(row[num])
            bookinfo["cover_h"] = tonumber(row[num + 1])
            if not get_cover then
                -- don't bother making a blitbuffer
                break
            end
            bookinfo["cover_bb"] = nil
            if bookinfo["has_cover"] then
                local bbtype = tonumber(row[num + 2])
                local bbstride = tonumber(row[num + 3])
                -- This is a blob_mt table! Essentially, a (ptr, size) tuple.
                local cover_blob = row[num + 4]
                -- The pointer returned by SQLite is only valid until the next step/reset/finalize!
                -- (which means its memory management is entirely in the hands of SQLite)
                local cover_data, cover_size = zstd.zstd_uncompress_ctx(cover_blob[1], cover_blob[2])
                -- Double-check that the size of the uncompressed BB is as expected...
                local expected_cover_size = bbstride * bookinfo["cover_h"]
                assert(cover_size == expected_cover_size,
                    "Uncompressed a " ..
                    tonumber(cover_size) .. "b BB instead of the expected " .. tonumber(expected_cover_size) .. "b")
                -- That one, on the other hand, is on the heap, so we can use it without making a copy.
                local cover_bb = Blitbuffer.new(bookinfo["cover_w"], bookinfo["cover_h"], bbtype, cover_data, bbstride,
                    bookinfo["cover_w"])
                -- Mark its data pointer as safe to free() on GC
                cover_bb:setAllocated(1)
                bookinfo["cover_bb"] = cover_bb
            end
            break
        end
    end

    self.get_stmt:clearbind():reset() -- get ready for next query
    return bookinfo
end

function BookInfoManager:getDocProps(filepath)
    local bookinfo
    local directory, filename = util.splitFilePathName(filepath)
    self:openDbConnection()
    local row = self.get_stmt:bind(directory, filename):step()
    if row ~= nil then
        bookinfo = {}
        for i = 13, 20 do
            bookinfo[BOOKINFO_COLS_SET[i]] = row[i]
        end
        bookinfo.pages = tonumber(bookinfo.pages)
    end
    self.get_stmt:clearbind():reset()
    return bookinfo
end

function BookInfoManager:extractBookInfo(filepath, cover_specs)
    local timer = ptdbg:new()
    -- This will be run in a subprocess
    -- We use a temporary directory for cre cache (that will not affect parent process),
    -- so we don't fill the main cache with books we're not actually reading
    if not self.cre_cache_overriden then
        -- We need to init engine (if no crengine book has yet been opened),
        -- so it does not reset our temporary cache dir when we first open
        -- a crengine book for extraction.
        local cre = require("document/credocument"):engineInit()
        -- If we wanted to disallow caching completely:
        -- cre.initCache("", 1024*1024*32) -- empty path = no cache
        -- But it's best to use a cache for quicker and less memory
        -- usage when opening big books:
        local default_cre_storage_size_factor = 20 -- note: keep in sync with the one in credocument.lua
        cre.initCache(self.tmpcr3cache, 0,         -- 0 = previous book caches are removed when opening a book
            true, G_reader_settings:readSetting("cre_storage_size_factor") or default_cre_storage_size_factor)
        self.cre_cache_overriden = true
    end

    local directory, filename = util.splitFilePathName(filepath)

    -- Initialize the new row that we will INSERT
    local dbrow = {}
    -- Actually no need to initialize with nil values:
    -- for dummy, col in ipairs(BOOKINFO_COLS_SET) do
    --     dbrow[col] = nil
    -- end
    dbrow.directory = directory
    dbrow.filename = filename

    -- To be able to catch a BAD book we have already tried to process but
    -- that made us crash, and that we would try to re-process again, we first
    -- insert a nearly empty row with in_progress = 1 (incremented if previously set)
    -- (This will also flag a book being processed when the user changed paged and
    -- kill the previous page background process, but well...)
    local tried_enough = false
    local prev_tries = 0
    -- Get nb of previous tries if record already there
    self:openDbConnection()
    self.in_progress_stmt:bind(directory, filename)
    local cur_in_progress = self.in_progress_stmt:step()
    self.in_progress_stmt:clearbind():reset() -- get ready for next query
    if cur_in_progress then
        prev_tries = tonumber(cur_in_progress[1])
    end
    -- Increment it and check if we have already tried enough
    if prev_tries < self.max_extract_tries then
        if prev_tries > 0 then
            logger.dbg(ptdbg.logprefix, "Seen", prev_tries, "previous attempts at info extraction", filepath, ", trying again")
        end
        dbrow.in_progress = prev_tries + 1 -- extraction not yet successful
    else
        logger.info(ptdbg.logprefix, "Seen", prev_tries, "previous attempts at info extraction", filepath, ", too many, ignoring it.")
        tried_enough = true
        dbrow.in_progress = 0     -- row will exist, we'll never be called again
        dbrow.unsupported = UNSUPPORTED_REASONS.too_many_interruptions_or_crashes.string
        dbrow.cover_fetched = 'Y' -- so we don't try again if we're called later with cover_specs
    end
    -- Insert the temporary "in progress" record (or the definitive "unsupported" record)
    for num, col in ipairs(BOOKINFO_COLS_SET) do
        self.set_stmt:bind1(num, dbrow[col])
    end
    self.set_stmt:step()              -- commited
    self.set_stmt:clearbind():reset() -- get ready for next query
    if tried_enough then
        return                        -- Last insert done for this book, we're giving up
    end

    -- Update this on each extraction attempt. Might be useful to reset the counter in case file gets updated.
    local file_attr = lfs.attributes(filepath)
    dbrow.filesize = file_attr.size
    dbrow.filemtime = file_attr.modification

    -- Proceed with extracting info
    local ReaderUI = require("apps/reader/readerui")
    local provider = ReaderUI:extendProvider(filepath, DocumentRegistry:getProvider(filepath))
    local document = DocumentRegistry:openDocument(filepath, provider)
    local loaded = true
    if document then
        local pages
        if document.loadDocument then                -- needed for crengine
            if not document:loadDocument(false) then -- load only metadata
                -- failed loading, calling other methods would segfault
                loaded = false
            else
                -- for credocument, number of pages returned by document:getPageCount() is wrong
                -- so instead, try finding pagecount in filename or calibre metadata
                local function getEstimatedPagecount(fname)
                    local filename_without_suffix, filetype = filemanagerutil.splitFileNameType(fname)

                    local fn_pagecount = string.match(filename_without_suffix, "P%((%d+)%)")
                    if fn_pagecount and fn_pagecount ~= "0" then
                        logger.dbg(ptdbg.logprefix, "Pagecount found in filename", fname, fn_pagecount)
                        return fn_pagecount
                    end

                    if filetype ~= "epub" then
                        logger.dbg(ptdbg.logprefix, "Skipping pagecount, not epub", fname)
                        return nil
                    end

                    local opf_file = nil
                    local locate_opf_command = "unzip " .. "-lqq \"" .. fname .. "\" \"*.opf\""
                    local opf_match_pattern = "(%S+%.opf)$"
                    local line = ""

                    if Device:isAndroid() then
                        -- fh style for Android
                        local fh = io.popen(locate_opf_command, "r")
                        while true and fh ~= nil do
                            line = fh:read()
                            if line == nil or opf_file ~= nil then
                                break
                            end
                            opf_file = string.match(line, opf_match_pattern)
                            logger.dbg(ptdbg.logprefix, line)
                        end
                    else
                        -- std_out style for POSIX
                        local std_out = nil
                        std_out = io.popen("unzip " .. "-lqq \"" .. fname .. "\" \"*.opf\"")
                        if std_out then
                            line = std_out:read()
                            opf_file = string.match(line, opf_match_pattern)
                            logger.dbg(ptdbg.logprefix, line)
                            std_out:close()
                        end
                    end

                    if opf_file then
                        local expand_opf_command = "unzip " .. "-p \"" .. fname .. "\" " .. "\"" .. opf_file .. "\""
                        local found_pages = nil
                        local found_value = nil
                        local do_break = false

                        local function parse_opf_file(fp, fv, l)
                            if fp then
                                -- multiline format, keep looking for the #values# line
                                fv = string.match(l, "\"#value#\": (%d+),")
                                if fv then
                                    return fp, fv, true
                                end
                                -- why category_sort? because it's always there and the props are stored alphabetically
                                -- so if we reach that before finding #value# it means there isn't one, which can happen
                                if string.match(l, "\"category_sort\":") then
                                    return fp, fv, true
                                end
                            else
                                fp = string.match(l, "#pages")
                                -- check for single line format
                                -- only look for a numerical value if #pages is found
                                if fp then
                                    fv = string.match(l, "&quot;#value#&quot;: (%d+),")
                                end
                                if fv then
                                    return fp, fv, true
                                end
                            end
                            return fp, fv, false
                        end

                        if Device:isAndroid() then
                            -- fh style for Android
                            local fh = io.popen(expand_opf_command, "r")
                            while true and fh ~= nil do
                                line = fh:read()
                                if line == nil then
                                    break
                                end
                                found_pages, found_value, do_break = parse_opf_file(found_pages, found_value, line)
                                if do_break then break end
                            end
                        else
                            -- std_out style for POSIX
                            local std_out = io.popen(expand_opf_command)
                            if std_out then
                                for std_line in std_out:lines() do
                                    found_pages, found_value, do_break = parse_opf_file(found_pages, found_value, std_line)
                                    if do_break then break end
                                end
                                std_out:close()
                            end
                        end
                        if found_value and found_value ~= "0" then
                            logger.dbg(ptdbg.logprefix, "Pagecount found in opf metadata ", fname, found_value)
                            return found_value
                        end
                    end
                    logger.dbg(ptdbg.logprefix, "Pagecount not found", fname)
                    return nil
                end
                local success, response = pcall(getEstimatedPagecount, filepath)
                if success then pages = response end
            end
        else
            -- for all others than crengine, we seem to get an accurate nb of pages
            pages = document:getPageCount()
        end
        if loaded then
            dbrow.pages = pages
            local props = FileManagerBookInfo.extendProps(document:getProps(), filepath)
            if next(props) then -- there's at least one item
                dbrow.has_meta = 'Y'
            end
            for k, v in pairs(props) do
                dbrow[k] = v
            end
            if cover_specs then
                -- ignore passed cover_specs, make cover at a fixed maximum and keep it forever
                local spec_max_cover_w = max_cover_dimen
                local spec_max_cover_h = max_cover_dimen
                dbrow.cover_fetched = 'Y' -- we had a try at getting a cover
                local cover_bb = FileManagerBookInfo:getCoverImage(document)
                if cover_bb then
                    dbrow.has_cover = 'Y'
                    -- we should scale down the cover to our max size
                    local cbb_w, cbb_h = cover_bb:getWidth(), cover_bb:getHeight()
                    dbrow.cover_sizetag = cbb_w .. "x" .. cbb_h -- store original cover size
                    if cbb_w > spec_max_cover_w or cbb_h > spec_max_cover_h then
                        -- scale down if bigger than what we will display
                        cbb_w, cbb_h = BookInfoManager.getCachedCoverSize(cbb_w, cbb_h, spec_max_cover_w,
                            spec_max_cover_h)
                        cover_bb = RenderImage:scaleBlitBuffer(cover_bb, cbb_w, cbb_h, true)
                    end
                    dbrow.cover_w = cover_bb.w
                    dbrow.cover_h = cover_bb.h
                    dbrow.cover_bb_type = cover_bb:getType()
                    dbrow.cover_bb_stride = tonumber(cover_bb.stride)
                    local cover_size = cover_bb.stride * cover_bb.h
                    local cover_zst_ptr, cover_zst_size = zstd.zstd_compress(cover_bb.data, cover_size)
                    dbrow.cover_bb_data = SQ3.blob(cover_zst_ptr, cover_zst_size) -- cast to blob for sqlite
                    logger.dbg(ptdbg.logprefix, "cover for", filename, "scaled from", dbrow.cover_sizetag, "to", cover_bb.w, "x",
                        cover_bb.h, ", compressed from", tonumber(cover_size), "to", tonumber(cover_zst_size))
                    -- We're done with the uncompressed bb now, and the compressed one has been managed by SQLite ;)
                    cover_bb:free()
                end
            end
        end
        document:close()
    else
        loaded = false
    end
    if not loaded then
        dbrow.unsupported = UNSUPPORTED_REASONS.not_readable_by_engine.string
        dbrow.cover_fetched = 'Y' -- so we don't try again if we're called later if cover_specs
    end
    dbrow.in_progress = 0         -- extraction completed (successful or definitive failure)
    for num, col in ipairs(BOOKINFO_COLS_SET) do
        self.set_stmt:bind1(num, dbrow[col])
    end
    self.set_stmt:step()
    self.set_stmt:clearbind():reset() -- get ready for next query
    timer:report("Cache book " .. filepath)
    return loaded
end

function BookInfoManager:setBookInfoProperties(filepath, props)
    -- If we need to set column=NULL, use props[column] = false (as
    -- props[column] = nil would make column disappear from props)
    local directory, filename = util.splitFilePathName(filepath)
    self:openDbConnection()
    -- Let's do multiple one-column UPDATE (easier than building
    -- a multiple columns UPDATE)
    local base_query = "UPDATE bookinfo SET %s=? WHERE directory=? AND filename=?;"
    for k, v in pairs(props) do
        local this_prop_query = string.format(base_query, k) -- add column name to query
        local stmt = self.db_conn:prepare(this_prop_query)
        if v == false then                                   -- convert false to nil (NULL)
            v = nil
        end
        stmt:bind(v, directory, filename)
        stmt:step()              -- commited
        stmt:clearbind():reset() -- cleanup
    end
end

function BookInfoManager:deleteBookInfo(filepath)
    local directory, filename = util.splitFilePathName(filepath)
    self:openDbConnection()
    local query = "DELETE FROM bookinfo WHERE directory=? AND filename=?;"
    local stmt = self.db_conn:prepare(query)
    stmt:bind(directory, filename)
    stmt:step()              -- commited
    stmt:clearbind():reset() -- cleanup
end

function BookInfoManager:removeNonExistantEntries()
    self:openDbConnection()
    local res = self.db_conn:exec("SELECT bcid, directory || filename FROM bookinfo;")
    if not res then
        return _("Cache is empty. Nothing to prune.")
    end
    local bcids = res[1]
    local filepaths = res[2]
    local bcids_to_remove = {}
    for i, filepath in ipairs(filepaths) do
        if lfs.attributes(filepath, "mode") ~= "file" then
            table.insert(bcids_to_remove, tonumber(bcids[i]))
        end
    end
    local query = "DELETE FROM bookinfo WHERE bcid=?;"
    local stmt = self.db_conn:prepare(query)
    for i = 1, #bcids_to_remove do
        stmt:bind(bcids_to_remove[i])
        stmt:step()              -- commited
        stmt:clearbind():reset() -- cleanup
    end
    return T(_("Removed %1 / %2 entries from cache."), #bcids_to_remove, #bcids)
end

-- Background extraction management
function BookInfoManager:collectSubprocesses()
    self.subprocesses_collector = nil

    -- We need to regularly watch if a sub-process has terminated by
    -- calling waitpid() so this process does not become a zombie hanging
    -- around till we exit.
    if #self.subprocesses_pids > 0 then
        -- In-place removal, hence the reverse iteration.
        for i = #self.subprocesses_pids, 1, -1 do
            local pid = self.subprocesses_pids[i]
            if FFIUtil.isSubProcessDone(pid) then
                table.remove(self.subprocesses_pids, i)
                -- Prevent has been issued for each bg task spawn, we must allow for each death too.
                UIManager:allowStandby()
            end
        end
        if #self.subprocesses_pids > 0 then
            -- still some pids around, we'll need to collect again
            self.subprocesses_collector = true
            UIManager:scheduleIn(
                self.subprocesses_collect_interval,
                function()
                    self:collectSubprocesses()
                end
            )
            -- If we're still waiting for some subprocess, and none have
            -- been submitted for some time, it's that one is stuck (and that
            -- the user has not left FileManager or changed page - that would
            -- have caused a terminateBackgroundJobs() - if we're here, it's
            -- that user has left reader in FileBrower and went away)
            if time.now() > self.subprocesses_last_added_time + self.subprocesses_killall_timeout_time then
                logger.warn(ptdbg.logprefix, "Some subprocesses were running for too long, killing them")
                self:terminateBackgroundJobs()
                -- we'll collect them next time we're run
            end
        else
            if self.delayed_cleanup then
                self.delayed_cleanup = false
                -- No more subprocesses = no more crengine indexing, we can remove our
                -- temporary cache directory
                self:cleanUp()
            end
        end
    end

    -- We're done, back to a single core
    if #self.subprocesses_pids == 0 then
        Device:enableCPUCores(1)
    end
end

function BookInfoManager:terminateBackgroundJobs()
    logger.dbg(ptdbg.logprefix, "terminating", #self.subprocesses_pids, "subprocesses")
    for i = 1, #self.subprocesses_pids do
        FFIUtil.terminateSubProcess(self.subprocesses_pids[i])
    end
end

function BookInfoManager:isExtractingInBackground()
    return #self.subprocesses_pids > 0
end

function BookInfoManager:extractInBackground(files)
    if #files == 0 then
        return
    end

    -- Terminate any previous extraction background task that would be still running
    self:terminateBackgroundJobs()

    -- Close current handle on sqlite, so it's not shared by both processes
    -- (both processes will re-open one when needed)
    BookInfoManager:closeDbConnection()

    -- Define task that will be run in subprocess
    local task = function()
        logger.dbg(ptdbg.logprefix, "  BG extraction started")
        for idx = 1, #files do
            local filepath = files[idx].filepath
            local cover_specs = files[idx].cover_specs
            logger.dbg(ptdbg.logprefix, "  BG extracting:", filepath)
            self:extractBookInfo(filepath, cover_specs)
        end
        logger.dbg(ptdbg.logprefix, "  BG extraction done")
    end

    self.cleanup_needed = true -- so we will remove temporary cache directory created by subprocess

    -- If it's the first subprocess we're launching, enable 2 CPU cores
    if #self.subprocesses_pids == 0 then
        Device:enableCPUCores(2)
    end

    -- Run task in sub-process, and remember its pid
    local task_pid = FFIUtil.runInSubProcess(task)
    if not task_pid then
        logger.warn(ptdbg.logprefix, "Failed lauching background extraction sub-process (fork failed)")
        return false -- let caller know it failed
    end
    -- No straight control flow exists for background task completion here, so we bump prevent
    -- counter on each task, and undo that inside collectSubprocesses() zombie reaper.
    UIManager:preventStandby()
    table.insert(self.subprocesses_pids, task_pid)
    self.subprocesses_last_added_time = time.now()

    -- We need to collect terminated jobs pids (so they do not stay "zombies"
    -- and fill linux processes table)
    -- We set a single scheduled action for that
    if not self.subprocesses_collector then -- there's not one already scheduled
        self.subprocesses_collector = true
        UIManager:scheduleIn(
            self.subprocesses_collect_interval,
            function()
                self:collectSubprocesses()
            end
        )
    end
    return true
end

function BookInfoManager:cleanUp()
    if #self.subprocesses_pids > 0 then
        -- Some background extraction may still use our tmpcr3cache,
        -- cleanup will be dealt with by BookInfoManager:collectSubprocesses()
        self.delayed_cleanup = true
        return
    end
    if self.cleanup_needed then
        logger.dbg(ptdbg.logprefix, "Removing directory", self.tmpcr3cache)
        FFIUtil.purgeDir(self.tmpcr3cache)
        self.cleanup_needed = false
    end
end

local function findFilesInDir(path, recursive)
    local dirs = { path }
    local files = {}
    local new_dirs = {}
    local fullpath
    local attributes

    while #dirs ~= 0 do
        new_dirs = {}
        -- handle each dir
        for __, d in pairs(dirs) do
            -- handle files in d
            for f in lfs.dir(d) do
                fullpath = d .. "/" .. f
                attributes = lfs.attributes(fullpath)
                -- Don't traverse hidden folders if we're not showing them
                if recursive and attributes.mode == "directory" and f ~= "." and f ~= ".." and (G_reader_settings:isTrue("show_hidden") or not util.stringStartsWith(f, ".")) then
                    table.insert(new_dirs, fullpath)
                    -- Always ignore macOS resource forks, too.
                elseif attributes.mode == "file" and not util.stringStartsWith(f, "._") and DocumentRegistry:hasProvider(fullpath) then
                    table.insert(files, fullpath)
                end
            end
        end
        dirs = new_dirs
    end
    return files
end

-- Batch extraction
function BookInfoManager:extractBooksInDirectory(path, cover_specs, autorun)
    local Geom = require("ui/geometry")
    local TopContainer = require("ui/widget/container/topcontainer")
    local Trapper = require("ui/trapper")
    local Screen = require("device").screen

    local automatic_mode = autorun or false
    local go_on
    local recursive
    local refresh_existing
    local prune
    if not automatic_mode then
        go_on = Trapper:confirm(_([[
This will extract metadata and cover images from books in the current directory.
Once extraction has started, you can abort at any moment by tapping on the screen.

This extraction may take time and use some battery power: you may wish to keep your device plugged in.]]
        ), _("Cancel"), _("Continue"))
        if not go_on then
            return
        end

        recursive = Trapper:confirm(_([[
Also extract book information from books in subdirectories?]]
            ),
            -- @translators Extract book information only for books in this directory.
            _("Here only"),
            -- @translators Extract book information for books in this directory as well as in subdirectories.
            _("Here and under"))

        refresh_existing = Trapper:confirm(_([[
Do you want to refresh metadata and covers that have already been extracted?]]
        ), _("Don't refresh"), _("Refresh"))

        prune = Trapper:confirm(_([[
If you have removed many books, or have renamed some directories, it is good to remove them from the cache database.

Do you want to prune the cache of removed books?]]
        ), _("Don't prune"), _("Prune"))

        Trapper:clear()
    else
        go_on = true
        recursive = true
        refresh_existing = false
        prune = false
    end

    local confirm_abort = function()
        return Trapper:confirm(_("Do you want to stop?"), _("Continue Indexing"), _("Stop Indexing"))
    end
    -- Cancel any background job, before we launch new ones
    self:terminateBackgroundJobs()

    local info, completed
    if prune then
        local summary
        while true do
            info = InfoMessage:new { text = _("Pruning cache of removed books…") }
            if not automatic_mode then UIManager:show(info) end
            UIManager:forceRePaint()
            completed, summary = Trapper:dismissableRunInSubprocess(function()
                return self:removeNonExistantEntries()
            end, info)
            if not completed then
                if confirm_abort() then
                    return
                end
            else
                self:compactDb() -- compact
                UIManager:close(info)
                info = InfoMessage:new { text = summary }
                UIManager:show(info)
                UIManager:forceRePaint()
                FFIUtil.sleep(2) -- Let the user see that
                break
            end
        end
        UIManager:close(info)
    end

    local files
    local filepaths

    while true do
        info = InfoMessage:new { text = _("Looking for books to index…") }
        if not automatic_mode then UIManager:show(info) end
        UIManager:forceRePaint()
        completed, files = Trapper:dismissableRunInSubprocess(function()
            filepaths = findFilesInDir(path, recursive)
            table.sort(filepaths)
            return filepaths
        end, info)
        if not completed then
            if confirm_abort() then
                return
            end
        elseif not files or #files == 0 then
            UIManager:close(info)
            if not automatic_mode then info = InfoMessage:new { text = _("No books were found.") } end
            UIManager:show(info)
            return
        else
            break
        end
    end
    UIManager:close(info)

    if refresh_existing then
        info = InfoMessage:new { text = T(N_("Found 1 book to index.", "Found %1 books to index.", #files), #files) }
        if not automatic_mode then UIManager:show(info) end
        UIManager:forceRePaint()
        FFIUtil.sleep(2) -- Let the user see that
    else
        local all_files = files
        local bookinfo
        local to_extract

        while true do
            info = InfoMessage:new { text = T(_("Found %1 books.\nLooking for new books…"), #all_files) }
            UIManager:show(info)
            UIManager:forceRePaint()
            FFIUtil.sleep(2) -- Let the user see that
            completed, files = Trapper:dismissableRunInSubprocess(function()
                files = {}
                for _, filepath in pairs(all_files) do
                    bookinfo = self:getBookInfo(filepath)
                    to_extract = not bookinfo
                    if bookinfo and cover_specs and not bookinfo.ignore_cover then
                        if bookinfo.cover_fetched then
                            --if bookinfo.has_cover and BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs) then
                            -- skip this. we're storing a single thumbnail res and that's it.
                            --end
                        else
                            to_extract = true
                        end
                    end
                    if to_extract then
                        table.insert(files, filepath)
                    end
                end
                return files
            end, info)
            if not completed then
                if confirm_abort() then
                    return
                end
            elseif not files or #files == 0 then
                UIManager:close(info)
                info = InfoMessage:new { text = _("No new books found.") }
                if not automatic_mode then UIManager:show(info) end
                return
            else
                break
            end
        end
        UIManager:close(info)
        info = InfoMessage:new { text = T(N_("Found 1 book to index.", "Found %1 books to index."), #files) }
        if not automatic_mode then UIManager:show(info) end
        UIManager:forceRePaint()
        if not automatic_mode then FFIUtil.sleep(2) end -- Let the user see that
    end
    UIManager:close(info)

    local nb_files = #files
    local nb_done = 0
    local nb_success = 0
    local i = 1

    -- We use a little hack to InfoMessage for a consistent height and
    -- fast refresh to avoid flicking
    info = InfoMessage:new { text = "dummy" }
    UIManager:show(info) -- but not yet painted
    local info_max_seen_height = 0
    local success

    local filepath
    local filename
    local d

    while i <= nb_files do
        filepath = files[i]
        filename = FFIUtil.basename(filepath)

        local orig_moved_offset = info.movable:getMovedOffset()
        info:free()
        info.text = T(_("Indexing %1 / %2…\n\n%3"), i, nb_files, BD.filename(filename)) .. "\n\n" .. _("Tap anywhere to stop")
        info:init()
        local text_widget = table.remove(info.movable[1][1], 3)
        local text_widget_size = text_widget:getSize()
        if text_widget_size.h > info_max_seen_height then
            info_max_seen_height = text_widget_size.h
        end
        table.insert(info.movable[1][1], TopContainer:new {
            dimen = Geom:new {
                w = text_widget_size.w,
                h = info_max_seen_height,
            },
            text_widget
        })
        info.movable[1][1]._size = nil -- reset HorizontalGroup size
        info.movable:setMovedOffset(orig_moved_offset)
        info:paintTo(Screen.bb, 0, 0)
        d = info.movable[1].dimen
        Screen.refreshUI(Screen, d.x, d.y, d.w, d.h)

        completed, success = Trapper:dismissableRunInSubprocess(function()
            return self:extractBookInfo(filepath, cover_specs)
        end, info)
        if not completed then
            if confirm_abort() then
                break
            end
            -- Recreate the infomessage that was dismissed
            info = InfoMessage:new { text = "dummy" }
            info.movable:setMovedOffset(orig_moved_offset)
            UIManager:show(info) -- but not yet painted
            -- don't increment i, re-process the one we interrupted
        else
            nb_done = nb_done + 1
            if success then
                nb_success = nb_success + 1
            end
            i = i + 1
        end
    end
    UIManager:close(info)
    info = InfoMessage:new { text = T(_("Processed %1 / %2 books."), nb_done, nb_files) .. "\n" .. T(N_("One extracted successfully.", "%1 extracted successfully.", nb_success), nb_success) }
    UIManager:show(info)
end

function BookInfoManager.getCachedCoverSize(img_w, img_h, max_img_w, max_img_h)
    local scale_factor
    local width = math.floor(max_img_h * img_w / img_h + 0.5)
    if max_img_w >= width then
        max_img_w = width
        scale_factor = max_img_w / img_w
    else
        max_img_h = math.floor(max_img_w * img_h / img_w + 0.5)
        scale_factor = max_img_h / img_h
    end
    return max_img_w, max_img_h, scale_factor
end

function BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs)
    if not bookinfo.cover_w or not bookinfo.cover_h then -- no thumbnail yet
        return true
    end
end

BookInfoManager:init()

return BookInfoManager
