local uvVersionGEQ = require('lib/utils').uvVersionGEQ
local isWindows = require('lib/utils').isWindows

return require('lib/tap')(function (test)

  test("read a file sync", function (print, p, expect, uv)
    local fd = assert(uv.fs_open('README.md', 'r', tonumber('644', 8)))
    p{fd=fd}
    local stat = assert(uv.fs_fstat(fd))
    p{stat=stat}
    local chunk = assert(uv.fs_read(fd, stat.size, 0))
    assert(#chunk == stat.size)
    assert(uv.fs_close(fd))
  end)

  test("read a file sync in chunks", function (print, p, expect, uv)
    local fd = assert(uv.fs_open('README.md', 'r', tonumber('644', 8)))
    local stat = assert(uv.fs_fstat(fd))
    local chunks = {}
    local numchunks = 8
    local chunksize = math.ceil(stat.size/numchunks)
    while true do
      local chunk, err = uv.fs_read(fd, chunksize)
      assert(not err, err)
      if #chunk == 0 then
        break
      end
      table.insert(chunks, chunk)
    end
    assert(#chunks == numchunks)
    assert(#table.concat(chunks) == stat.size)
    assert(uv.fs_close(fd))
  end)

  test("read a file async", function (print, p, expect, uv)
    uv.fs_open('README.md', 'r', tonumber('644', 8), expect(function (err, fd)
      assert(not err, err)
      p{fd=fd}
      uv.fs_fstat(fd, expect(function (err, stat)
        assert(not err, err)
        p{stat=stat}
        uv.fs_read(fd, stat.size, 0, expect(function (err, chunk)
          assert(not err, err)
          p{chunk=#chunk}
          assert(#chunk == stat.size)
          uv.fs_close(fd, expect(function (err)
            assert(not err, err)
          end))
        end))
      end))
    end))
  end)

  test("fs.write", function (print, p, expect, uv)
    local path = "_test_"
    local fd = assert(uv.fs_open(path, "w", 438))
    -- a mix of async and sync
    uv.fs_write(fd, "Hello World\n", expect(function(err, n)
      assert(not err, err)
      assert(uv.fs_write(fd, {"with\n", "more\n", "lines\n"}))
      assert(uv.fs_close(fd))
      assert(uv.fs_unlink(path))
    end))
  end)

  -- collect garbage after uv.fs_write but before the write callback
  -- is called in order to potentially garbage collect the strings that
  -- are being sent. See https://github.com/luvit/luv/issues/397
  test("fs.write data refs", function (print, p, expect, uv)
    local path = "_test_"
    local fd = assert(uv.fs_open(path, "w+", tonumber("0666", 8)))
    do
      -- the number here gets coerced into a string
      local t = {"with", 600, "lines"}
      uv.fs_write(fd, t, function()
        local expectedContents = table.concat(t)
        local stat = assert(uv.fs_fstat(fd))
        assert(stat.size == #expectedContents)
        local chunk = assert(uv.fs_read(fd, stat.size, 0))
        assert(chunk == expectedContents)
        assert(uv.fs_close(fd))
        assert(uv.fs_unlink(path))
      end)
    end
    local count = collectgarbage("count")
    collectgarbage("collect")
    assert(count - collectgarbage("count") > 0)
  end)

  test("fs.stat sync", function (print, p, expect, uv)
    local stat = assert(uv.fs_stat("README.md"))
    assert(stat.size)
  end)

  test("fs.stat async", function (print, p, expect, uv)
    assert(uv.fs_stat("README.md", expect(function (err, stat)
      assert(not err, err)
      assert(stat.size)
    end)))
  end)

  test("fs.stat sync error", function (print, p, expect, uv)
    local stat, err, code = uv.fs_stat("BAD_FILE!")
    p{err=err,code=code,stat=stat}
    assert(not stat)
    assert(err)
    assert(code == "ENOENT")
  end)

  test("fs.stat async error", function (print, p, expect, uv)
    assert(uv.fs_stat("BAD_FILE@", expect(function (err, stat)
      p{err=err,stat=stat}
      assert(err)
      assert(not stat)
    end)))
  end)

  test("fs.scandir", function (print, p, expect, uv)
    local req = uv.fs_scandir('.')
    local function iter()
      return uv.fs_scandir_next(req)
    end
    for name, ftype in iter do
      p{name=name, ftype=ftype}
      assert(name)
      -- ftype is not available in all filesystems; for example it's
      -- provided for HFS+ (OSX), NTFS (Windows) but not for ext4 (Linux).
    end
  end)

  test("fs.scandir sync error", function (print, p, expect, uv)
    local req, err, code = uv.fs_scandir('BAD_FILE!')
    p{err=err,code=code,req=req}
    assert(not req)
    assert(err)
    assert(code == "ENOENT")
  end)

  test("fs.scandir async error", function (print, p, expect, uv)
    local _req, _err = uv.fs_scandir('BAD_FILE!', expect(function(err, req)
      p{err=err,req=req}
      assert(not req)
      assert(err)
    end))
    -- Note: when using the async version, the initial return only errors
    -- if there is an error when setting up the internal Libuv call
    -- (e.g. if there's an out-of-memory error when copying the path).
    -- So even though the callback will have an error, the initial call
    -- should return a valid uv_fs_t userdata without an error.
    assert(_req)
    assert(not _err)
  end)

  test("fs.scandir async", function (print, p, expect, uv)
    assert(uv.fs_scandir('.', function(err, req)
      assert(not err)
      local function iter()
        return uv.fs_scandir_next(req)
      end
      for name, ftype in iter do
        p{name=name, ftype=ftype}
        assert(name)
        -- ftype is not available in all filesystems; for example it's
        -- provided for HFS+ (OSX), NTFS (Windows) but not for ext4 (Linux).
      end
    end))
  end)

  -- this test does nothing on its own, but when run with a leak checker,
  -- it will check that the memory allocated by Libuv for req is cleaned up
  -- even if its not iterated fully (or at all)
  test("fs.scandir with no iteration", function(print, p, expect, uv)
    local req = uv.fs_scandir('.')
    assert(req)
  end)

  -- this previously hit a use-after-free
  -- see https://github.com/luvit/luv/pull/696
  test("fs.scandir given to new_work", function(print, p, expect, uv)
    local req = assert(uv.fs_scandir('.'))
    local work
    work = assert(uv.new_work(function(_entries)
      local _uv = require('luv')
      while true do
        if not _uv.fs_scandir_next(_entries) then break end
      end
    end, function() end))
    work:queue(req)
  end)

  test("fs.realpath", function (print, p, expect, uv)
    p(assert(uv.fs_realpath('.')))
    assert(uv.fs_realpath('.', expect(function (err, path)
      assert(not err, err)
      p(path)
    end)))
  end, "1.8.0")

  test("fs.copyfile", function (print, p, expect, uv)
    local path = "_test_"
    local path2 = "_test2_"
    local fd = assert(uv.fs_open(path, "w", 438))
    uv.fs_write(fd, "Hello World\n", -1)
    uv.fs_close(fd)
    assert(uv.fs_copyfile(path, path2))
    assert(uv.fs_unlink(path))
    assert(uv.fs_unlink(path2))
  end, "1.14.0")

  test("fs.{open,read,close}dir object sync #1", function(print, p, expect, uv)
    local dir = assert(uv.fs_opendir('.'))
    repeat
      local dirent = dir:readdir()
      if dirent then
        assert(#dirent==1)
        p(dirent)
      end
    until not dirent
    assert(dir:closedir()==true)
  end, "1.28.0")

  test("fs.{open,read,close}dir object sync #2", function(print, p, expect, uv)
    local dir = assert(uv.fs_opendir('.'))
    repeat
      local dirent = dir:readdir()
      if dirent then
        assert(#dirent==1)
        p(dirent)
      end
    until not dirent
    dir:closedir(function(err, state)
      assert(err==nil)
      assert(state==true)
      assert(tostring(dir):match("^uv_dir_t"))
      print(dir, 'closed')
    end)
  end, "1.28.0")

  test("fs.{open,read,close}dir sync one entry", function(print, p, expect, uv)
    local dir = assert(uv.fs_opendir('.'))
    repeat
      local dirent = uv.fs_readdir(dir)
      if dirent then
        assert(#dirent==1)
        p(dirent)
      end
    until not dirent
    assert(uv.fs_closedir(dir)==true)
  end, "1.28.0")

  test("fs.{open,read,close}dir sync more entry", function(print, p, expect, uv)
    local dir = assert(uv.fs_opendir('.', nil, 50))
    repeat
      local dirent = uv.fs_readdir(dir)
      if dirent then p(dirent) end
    until not dirent
    assert(uv.fs_closedir(dir)==true)
  end, "1.28.0")

  test("fs.{open,read,close}dir with more entry", function(print, p, expect, uv)
    local function opendir_cb(err, dir)
      assert(not err)
      local function readdir_cb(err, dirs)
        assert(not err)
        if dirs then
          p(dirs)
          uv.fs_readdir(dir, readdir_cb)
        else
          assert(uv.fs_closedir(dir)==true)
        end
      end

      uv.fs_readdir(dir, readdir_cb)
    end
    assert(uv.fs_opendir('.', opendir_cb, 50))
  end, "1.28.0")

  test("fs.opendir and fs.closedir in a loop", function(print, p, expect, uv)
    -- Previously, this triggered a GC/closedir race condition
    -- see https://github.com/luvit/luv/issues/597
    for _ = 1,1000 do
      local dir, err = uv.fs_opendir('.', nil, 64)
      if not err then
        uv.fs_closedir(dir)
      end
    end
  end, "1.28.0")

  test("fs.{open,read,close}dir ref check", function(print, p, expect, uv)
    local dir = assert(uv.fs_opendir('.', nil, 50))

    local function readdir_cb(err, dirs)
      assert(not err)
      if dirs then
        p(dirs)
      end
    end

    uv.fs_readdir(dir, readdir_cb)
    dir = nil
    collectgarbage()
    collectgarbage()
    collectgarbage()

  end, "1.28.0")

  test("fs.statfs sync", function (print, p, expect, uv)
    local stat = assert(uv.fs_statfs("."))
    p(stat)
    assert(stat.bavail>0)
  end, "1.31.0")

  test("fs.statfs async", function (print, p, expect, uv)
    assert(uv.fs_statfs(".", expect(function (err, stat)
      assert(not err, err)
      p(stat)
      assert(stat.bavail>0)
    end)))
  end, "1.31.0")

  test("fs.statfs sync error", function (print, p, expect, uv)
    local stat, err, code = uv.fs_statfs("BAD_FILE!")
    p{err=err,code=code,stat=stat}
    assert(not stat)
    assert(err)
    assert(code == "ENOENT")
  end, "1.31.0")

  test("fs.statfs async error", function (print, p, expect, uv)
    assert(uv.fs_statfs("BAD_FILE@", expect(function (err, stat)
      p{err=err,stat=stat}
      assert(err)
      assert(not stat)
    end)))
  end, "1.31.0")

  test("fs.mkdtemp async", function(print, p, expect, uv)
    local tp = "luvXXXXXX"
    uv.fs_mkdtemp(tp, function(err, path)
      assert(not err)
      assert(path:match("^luv......"))
      assert(uv.fs_rmdir(path))
    end)
  end)

  test("fs.mkdtemp sync", function(print, p, expect, uv)
    local tp = "luvXXXXXX"
    local path, err, code = uv.fs_mkdtemp(tp)
    assert(path:match("^luv......"))
    assert(uv.fs_rmdir(path))
  end)

  test("fs.mkdtemp async error", function(print, p, expect, uv)
    local tp = "luvXXXXXZ"
    uv.fs_mkdtemp(tp, function(err, path)
      -- Will success on MacOS
      if not err then
        assert(path:match("^luv......"))
        assert(uv.fs_rmdir(path))
      else
        assert(err:match("^EINVAL:"))
        assert(path==nil)
      end
    end)
  end)

  test("fs.mkdtemp sync error", function(print, p, expect, uv)
    local tp = "luvXXXXXZ"
    local path, err, code = uv.fs_mkdtemp(tp)
    -- Will success on MacOS
    if not err then
      assert(path:match("^luv......"))
      assert(uv.fs_rmdir(path))
    else
      assert(path==nil)
      assert(err:match("^EINVAL:"))
      assert(code=='EINVAL')
    end
  end)

  test("fs.mkstemp async", function(print, p, expect, uv)
    local tp = "luvXXXXXX"
    uv.fs_mkstemp(tp, function(err, fd, path)
      assert(not err)
      assert(type(fd)=='number')
      assert(path:match("^luv......"))
      assert(uv.fs_close(fd))
      assert(uv.fs_unlink(path))
    end)
  end, "1.34.0")

  test("fs.mkstemp sync", function(print, p, expect, uv)
    local tp = "luvXXXXXX"
    local content = "hello world!"
    local fd, path = uv.fs_mkstemp(tp)
    assert(type(fd)=='number')
    assert(path:match("^luv......"))
    uv.fs_write(fd, content, -1)
    assert(uv.fs_close(fd))

    fd = assert(uv.fs_open(path, "r", 438))
    local stat = assert(uv.fs_fstat(fd))
    local chunk = assert(uv.fs_read(fd, stat.size, 0))
    assert(#chunk == stat.size)
    assert(chunk==content)
    assert(uv.fs_close(fd))
    assert(uv.fs_unlink(path))
  end, "1.34.0")

  test("fs.mkstemp async error", function(print, p, expect, uv)
    local tp = "luvXXXXXZ"
    uv.fs_mkstemp(tp, function(err, path, fd)
      assert(err:match("^EINVAL:"))
      assert(path==nil)
      assert(fd==nil)
    end)
  end, "1.34.0")

  test("fs.mkstemp sync error", function(print, p, expect, uv)
    local tp = "luvXXXXXZ"
    local path, err, code = uv.fs_mkstemp(tp)
    assert(path==nil)
    assert(err:match("^EINVAL:"))
    assert(code=='EINVAL')
  end, "1.34.0")

  test("errors with dest paths", function (print, p, expect, uv)
    -- this combination will cause all of the functions below to fail
    local path1, path2 = "_test_", "_testdir_"
    local fd1 = assert(uv.fs_open(path1, "w", 438))
    assert(uv.fs_close(fd1))
    assert(uv.fs_mkdir(path2, tonumber('777', 8)))

    local fns = {"fs_rename", "fs_link", "fs_symlink", "fs_copyfile"}
    for _, fn_name in ipairs(fns) do
      if uv[fn_name] then
        local fn = uv[fn_name]
        local ok, err, code = fn(path1, path2)
        p(fn_name, ok, err, code)
        assert(not ok)
      end
    end

    assert(uv.fs_unlink(path1))
    assert(uv.fs_rmdir(path2))
  end)

  local isfinite = function(v)
     -- `v == v` rules out nan
    return v ~= math.huge and v == v
  end

  local check_utime = function(uv, path, atime, mtime, test_lutime)
    local statfn = test_lutime and uv.fs_lstat or uv.fs_stat
    local stat = assert(statfn(path))

    if isfinite(atime) then
      -- very approximate check, different systems have different precisions
      assert(stat.atime.sec >= atime - 1)
      assert(stat.atime.sec <= atime)
    elseif atime == math.huge then -- "now"
      -- arbitrary timestamp more recent than the timestamps we use in the tests
      assert(stat.atime.sec > 1739710000)
    end

    if isfinite(mtime) then
      -- very approximate check, different systems have different precisions
      assert(stat.mtime.sec >= mtime - 1)
      assert(stat.mtime.sec <= mtime)
    elseif mtime == math.huge then -- "now"
      -- arbitrary timestamp more recent than the timestamps we use in the tests
      assert(stat.mtime.sec > 1739710000)
    end
  end

  local function test_utime(utimefn, path, path_or_fd, test_lutime, print, p, expect, uv, cb)
    local atime = 400497753.25 -- 1982-09-10 11:22:33.25
    local mtime = atime

    assert(utimefn(path_or_fd, atime, mtime))
    check_utime(uv, path, atime, mtime, test_lutime)

    if uvVersionGEQ("1.51.0") then
      -- omit both atime and mtime, using all possible parameter variants
      assert(utimefn(path_or_fd))
      check_utime(uv, path, atime, mtime, test_lutime)

      assert(utimefn(path_or_fd, nil, nil))
      check_utime(uv, path, atime, mtime, test_lutime)

      assert(utimefn(path_or_fd, "omit", "omit"))
      check_utime(uv, path, atime, mtime, test_lutime)

      assert(utimefn(path_or_fd, uv.constants.FS_UTIME_OMIT, uv.constants.FS_UTIME_OMIT))
      check_utime(uv, path, atime, mtime, test_lutime)

      -- atime now
      assert(utimefn(path_or_fd, "now", nil))
      check_utime(uv, path, uv.constants.FS_UTIME_NOW, mtime, test_lutime)

      -- reset atime/mtime
      assert(utimefn(path_or_fd, atime, mtime))
      check_utime(uv, path, atime, mtime, test_lutime)

      -- atime now
      assert(utimefn(path_or_fd, uv.constants.FS_UTIME_NOW, nil))
      check_utime(uv, path, uv.constants.FS_UTIME_NOW, mtime, test_lutime)

      -- reset atime/mtime
      assert(utimefn(path_or_fd, atime, mtime))
      check_utime(uv, path, atime, mtime, test_lutime)

      -- mtime now
      assert(utimefn(path_or_fd, nil, "now"))
      check_utime(uv, path, atime, uv.constants.FS_UTIME_NOW, test_lutime)

      -- reset atime/mtime
      assert(utimefn(path_or_fd, atime, mtime))
      check_utime(uv, path, atime, mtime, test_lutime)

      -- mtime now
      assert(utimefn(path_or_fd, nil, uv.constants.FS_UTIME_NOW))
      check_utime(uv, path, atime, uv.constants.FS_UTIME_NOW, test_lutime)
    end

    -- async
    atime = 1291404900.25; -- 2010-12-03 20:35:00.25
    mtime = atime

    assert(utimefn(path_or_fd, atime, mtime, expect(function(err)
      assert(not err, err)
      check_utime(uv, path, atime, mtime, test_lutime)
      if cb then cb() end
    end)))
  end

  test("fs.utime", function(print, p, expect, uv)
    local path = "_test_"
    local fd = assert(uv.fs_open(path, "w+", 438))
    assert(uv.fs_close(fd))

    test_utime(uv.fs_utime, path, path, false, print, p, expect, uv, function()
      assert(uv.fs_unlink(path))
    end)
  end)

  test("fs.futime", function(print, p, expect, uv)
    local path = "_test_"
    local fd = assert(uv.fs_open(path, "w+", 438))

    test_utime(uv.fs_futime, path, fd, false, print, p, expect, uv, function()
      assert(uv.fs_close(fd))
      assert(uv.fs_unlink(path))
    end)
  end)

  test("fs.lutime", function(print, p, expect, uv)
    local path = "_test_"
    local symlink_path = "_test_symlink_"
    local fd = assert(uv.fs_open(path, "w+", 438))
    assert(uv.fs_close(fd))

    uv.fs_unlink(symlink_path)
    local ok, err, errname = uv.fs_symlink(path, symlink_path)
    if not ok and isWindows and errname == "EPERM" then
      -- Creating a symlink on Windows can require extra privileges
      print("Insufficient privileges to create symlink, skipping")
      return
    end
    assert(ok, err)

    test_utime(uv.fs_lutime, symlink_path, symlink_path, true, print, p, expect, uv, function()
      assert(uv.fs_unlink(symlink_path))
      assert(uv.fs_unlink(path))
    end)
  end, "1.36.0")
end)
