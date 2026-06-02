<?php
/**
 * extract-duparchive.php
 *
 * PHP-CLI extractor for Duplicator Pro `.daf` archives (DupArchive format,
 * NOT a standard zip). Reuses the Duplicator-bundled DupArchive classes that
 * ship inside any Duplicator `installer.php`, so it works for any version
 * without external dependencies.
 *
 * Strategy:
 *   1. Read installer.php source.
 *   2. Find the final global `namespace { ... }` block at the file tail,
 *      which contains the bootstrap execution (BootstrapRunner::run() etc.)
 *      that would otherwise extract dup-installer/, hook error handlers,
 *      and try to render HTML.
 *   3. Truncate at that position, append a harmless empty `namespace {}`,
 *      write to a temp file, and require it. This loads ALL the
 *      Duplicator\Libs\DupArchive\* classes without firing the installer.
 *   4. Call DupArchiveExpandBasicEngine::expandDirectory() to stream the
 *      archive to disk, file by file.
 *
 * Usage:
 *   php extract-duparchive.php <installer.php> <archive.daf> <destDir>
 *
 * Exits 0 on success, non-zero on error. Progress + per-file log goes to STDERR.
 */
declare(strict_types=1);

if ($argc < 4) {
    fwrite(STDERR, "Usage: php extract-duparchive.php <installer.php> <archive.daf> <destDir>\n");
    exit(2);
}

[, $installerPath, $archivePath, $destDir] = $argv;

foreach (['installer.php' => $installerPath, 'archive.daf' => $archivePath] as $label => $p) {
    if (!is_readable($p)) {
        fwrite(STDERR, "[extract] ERROR: $label not readable: $p\n");
        exit(1);
    }
}

if (!is_dir($destDir) && !@mkdir($destDir, 0755, true)) {
    fwrite(STDERR, "[extract] ERROR: cannot create dest dir: $destDir\n");
    exit(1);
}
$destDir = rtrim(realpath($destDir), '/');

fwrite(STDERR, "[extract] installer = $installerPath\n");
fwrite(STDERR, "[extract] archive   = $archivePath (" . number_format(filesize($archivePath)) . " bytes)\n");
fwrite(STDERR, "[extract] dest      = $destDir\n");

$src = file_get_contents($installerPath);
if ($src === false) {
    fwrite(STDERR, "[extract] ERROR: cannot read installer.php\n");
    exit(1);
}

// Locate the final global `namespace {` block (it always comes at the very end
// of a Duplicator installer, holding the BootstrapRunner::run() invocation).
$finalNsPos = strrpos($src, "\nnamespace {");
if ($finalNsPos === false) {
    fwrite(STDERR, "[extract] ERROR: could not locate final 'namespace {' block in installer.php\n");
    exit(1);
}

$safe = substr($src, 0, $finalNsPos)
      . "\nnamespace { /* bootstrap execution suppressed by extract-duparchive.php */ }\n";

$tmpFile = tempnam(sys_get_temp_dir(), 'dup-lib-') . '.php';
if (file_put_contents($tmpFile, $safe) === false) {
    fwrite(STDERR, "[extract] ERROR: cannot write temp lib at $tmpFile\n");
    exit(1);
}

try {
    require $tmpFile;
} finally {
    @unlink($tmpFile);
}

$engineClass = 'Duplicator\\Libs\\DupArchive\\DupArchiveExpandBasicEngine';
if (!class_exists($engineClass)) {
    fwrite(STDERR, "[extract] ERROR: $engineClass not loaded — installer.php structure may differ\n");
    exit(1);
}

$progress = ['files' => 0, 'dirs' => 0, 'bytes' => 0, 'lastTick' => microtime(true)];

$engineClass::setCallbacks(
    // log callback
    function ($s, $flush = false) use (&$progress) {
        // Quiet down: only show MINI EXPAND lines containing notable events
        if (stripos($s, 'error') !== false || stripos($s, 'fail') !== false) {
            fwrite(STDERR, $s . "\n");
        }
    },
    // chmod callback
    function ($path, $perms) {
        return @chmod($path, 0644);
    },
    // mkdir callback
    function ($path, $perms, $recursive) use (&$progress) {
        $ok = is_dir($path) ? true : @mkdir($path, 0755, $recursive);
        if ($ok) {
            $progress['dirs']++;
        }
        return $ok;
    }
);

// In DupArchive the main content is stored from the start of the archive up
// to a terminator, then "extra files" (dup-installer/, dup-database__*.sql)
// are appended after the terminator. We therefore must call expandDirectory
// twice: once with offset=0 to extract the main payload, and once with
// offset=$extraOffset to extract the appended extras.
$extraOffset = $engineClass::getExtraOffset($archivePath, '');
fwrite(STDERR, "[extract] dup-installer extras offset = $extraOffset\n");
$startTs = microtime(true);

// Periodic progress thread via pcntl is overkill here — we just report on file complete
// by monkey-patching the chmod callback to count files (chmod is called once per file).
$engineClass::setCallbacks(
    function ($s, $flush = false) {
        if (stripos($s, 'error') !== false || stripos($s, 'fail') !== false) {
            fwrite(STDERR, $s . "\n");
        }
    },
    function ($path, $perms) use (&$progress, $startTs) {
        @chmod($path, 0644);
        $progress['files']++;
        $progress['bytes'] += @filesize($path) ?: 0;
        $now = microtime(true);
        if (($now - $progress['lastTick']) >= 5.0) {
            $progress['lastTick'] = $now;
            $elapsed = $now - $startTs;
            fwrite(STDERR, sprintf(
                "[extract] progress: %d files, %d dirs, %.2f GB written, %.0fs elapsed\n",
                $progress['files'], $progress['dirs'], $progress['bytes'] / 1073741824, $elapsed
            ));
        }
        return true;
    },
    function ($path, $perms, $recursive) use (&$progress) {
        $ok = is_dir($path) ? true : @mkdir($path, 0755, $recursive);
        if ($ok) {
            $progress['dirs']++;
        }
        return $ok;
    }
);

try {
    fwrite(STDERR, "[extract] Pass 1/2: main payload (offset=0)...\n");
    $engineClass::expandDirectory($archivePath, '', $destDir, '', false, 0);
    fwrite(STDERR, sprintf(
        "[extract] Pass 1 done: %d files, %d dirs, %.2f GB\n",
        $progress['files'], $progress['dirs'], $progress['bytes'] / 1073741824
    ));
    if ($extraOffset > 0) {
        fwrite(STDERR, "[extract] Pass 2/2: dup-installer extras (offset=$extraOffset)...\n");
        $engineClass::expandDirectory($archivePath, '', $destDir, '', false, $extraOffset);
    } else {
        fwrite(STDERR, "[extract] No extras pass needed (offset=0)\n");
    }
} catch (Throwable $e) {
    fwrite(STDERR, "[extract] FATAL: " . $e->getMessage() . "\n");
    fwrite(STDERR, $e->getTraceAsString() . "\n");
    exit(1);
}

$elapsed = microtime(true) - $startTs;
fwrite(STDERR, sprintf(
    "[extract] DONE. %d files, %d dirs, %.2f GB written in %.0fs.\n",
    $progress['files'], $progress['dirs'], $progress['bytes'] / 1073741824, $elapsed
));
exit(0);
