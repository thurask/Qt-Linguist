<#
.SYNOPSIS
    Builds static Qt Linguist tools for Windows and packages them as linguist_<version>.zip.

.DESCRIPTION
    Clones only the Qt modules Linguist needs (not the whole of Qt), configures a static
    release build with MSVC 2022, builds just the Linguist targets plus translations, checks
    the result and zips it.

    Qt 6.x builds 64-bit with CMake/Ninja. Qt 5.15.x builds 32-bit with qmake/jom from the
    -lts-lgpl tags, matching the existing releases.

    Requires: Visual Studio 2022 with the C++ workload, Git, Python, CMake and Ninja (Qt 6),
    Perl (Qt 5). Run from PowerShell 7.2+; no developer prompt needed.

.EXAMPLE
    .\scripts\build.ps1 -Version 6.12.0
.EXAMPLE
    .\scripts\build.ps1 -Version 5.15.19 -WorkDir D:\qtl5
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(5\.15|6\.\d+)\.\d+$')]
    [string]$Version,

    # Keep this short: Qt builds on Windows run into MAX_PATH with deep paths.
    [string]$WorkDir = 'C:\qtl',

    [string]$OutDir = (Join-Path (Get-Location) 'dist'),

    [string]$GitBase = 'https://github.com/qt',

    [int]$Jobs = [Environment]::ProcessorCount,

    # vswhere version range. [17.0,18.0) = Visual Studio 2022.
    [string]$VsVersion = '[17.0,18.0)'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$IsQt5 = $Version.StartsWith('5.')
$Tag = if ($IsQt5) { "v$Version-lts-lgpl" } else { "v$Version" }
$Arch = if ($IsQt5) { 'x86' } else { 'x64' }

# qtshadertools is only a "recommends" for qtdeclarative, but Qt Quick will not build without
# qsb, and Linguist 6.12+ links Qt Quick Widgets. Qt 5 has no qtshadertools.
$Modules = if ($IsQt5) {
    'qtbase', 'qtdeclarative', 'qttools', 'qttranslations'
} else {
    'qtbase', 'qtshadertools', 'qtdeclarative', 'qttools', 'qttranslations'
}

# Every tool that has shipped in a release. Whatever the given version builds gets packaged.
$ToolNames = 'linguist', 'lupdate', 'lupdate-pro', 'lrelease', 'lrelease-pro',
             'lconvert', 'lprodump', 'ltext2id', 'lcheck'

$Src = Join-Path $WorkDir 's'
$Bld = Join-Path $WorkDir 'b'
$Stage = Join-Path $WorkDir 'pkg'

function Invoke-Exe([string]$Exe, [string[]]$ArgList) {
    Write-Host "> $Exe $($ArgList -join ' ')"
    # Out-Host keeps tool output out of the function's return value.
    & $Exe @ArgList | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited with code $LASTEXITCODE" }
}

function Enter-Msvc {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -products * -version $VsVersion `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw "No Visual Studio $VsVersion install with C++ tools found." }
    Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation `
        -DevCmdArguments "-arch=$Arch -host_arch=x64 -no_logo" | Out-Null
    Write-Host "MSVC environment: $vs ($Arch)"
}

function Get-QtSource {
    if (Test-Path $Src) { Remove-Item $Src -Recurse -Force }
    $git = @('-c', 'advice.detachedHead=false', '-c', 'core.autocrlf=false', '-c', 'core.longpaths=true',
             'clone', '--quiet', '--depth', '1', '--branch', $Tag)
    Invoke-Exe git ($git + @("$GitBase/qt5.git", $Src))
    foreach ($m in $Modules) {
        $dir = Join-Path $Src $m
        # The super-repo checkout leaves an empty directory for each uninitialised submodule.
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        Invoke-Exe git ($git + @("$GitBase/$m.git", $dir))
    }
}

function Build-Qt6 {
    if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) { throw 'ninja not found on PATH.' }

    $configure = @(
        '-release', '-opensource', '-platform', 'win32-msvc', '-static', '-static-runtime',
        '-nomake', 'examples', '-nomake', 'tests', '-nomake', 'benchmarks',
        '-nomake', 'manual-tests', '-nomake', 'minimal-static-tests',
        '-qt-doubleconversion', '-qt-zlib', '-qt-libjpeg', '-qt-libpng', '-qt-freetype',
        '-qt-pcre', '-qt-harfbuzz', '-qt-sqlite',
        '-opengl', 'dynamic',
        # Assistant needs the qlitehtml git submodule of qttools, which a plain clone doesn't
        # fetch, and Linguist doesn't use it.
        '-no-feature-assistant',
        '-prefix', (Join-Path $WorkDir 'install')
    )
    Push-Location $Bld
    try { Invoke-Exe (Join-Path $Src 'configure.bat') $configure } finally { Pop-Location }
    # The top-level configure.bat can exit 0 after CMake fails; no build.ninja means it failed.
    if (-not (Test-Path (Join-Path $Bld 'build.ninja'))) { throw 'configure failed; see the CMake errors above.' }

    # Build only what ends up in the zip (and its dependencies), not all five modules.
    $targets = @(foreach ($t in $ToolNames + 'updateqm') {
        & ninja -C $Bld -t query $t *> $null
        if ($LASTEXITCODE -eq 0) { $t }
    })
    if ('linguist' -notin $targets) {
        throw 'The linguist target was not generated. Check the configure output for missing features (Qt Quick, Widgets).'
    }
    Invoke-Exe cmake (@('--build', $Bld, '--parallel', "$Jobs", '--target') + $targets)

    return @{ Bin = Join-Path $Bld 'qtbase\bin'; Translations = Join-Path $Bld 'qtbase\translations' }
}

function Build-Qt5 {
    if (-not (Get-Command perl -ErrorAction SilentlyContinue)) { throw 'perl not found on PATH.' }
    if (-not (Get-Command jom -ErrorAction SilentlyContinue)) {
        $jomDir = Join-Path $WorkDir 'jom'
        New-Item -ItemType Directory -Force $jomDir | Out-Null
        $zip = Join-Path $jomDir 'jom.zip'
        Invoke-WebRequest 'https://download.qt.io/official_releases/jom/jom.zip' -OutFile $zip
        Expand-Archive $zip -DestinationPath $jomDir -Force
        $env:Path = "$jomDir;$env:Path"
    }

    # -qt-tiff/-qt-webp from the manual instructions belong to qtimageformats, which isn't
    # cloned here; Qt 5 configure rejects options for absent modules.
    $configure = @(
        '-release', '-opensource', '-confirm-license', '-platform', 'win32-msvc',
        '-static', '-static-runtime', '-nomake', 'examples', '-nomake', 'tests',
        '-qt-doubleconversion', '-qt-zlib', '-qt-libjpeg', '-qt-libpng', '-qt-freetype',
        '-qt-pcre', '-qt-harfbuzz', '-qt-sqlite',
        '-opengl', 'dynamic',
        '-prefix', (Join-Path $WorkDir 'install')
    )
    Push-Location $Bld
    try {
        Invoke-Exe (Join-Path $Src 'configure.bat') $configure
        if (-not (Test-Path 'Makefile')) { throw 'configure failed; see the errors above.' }
        Invoke-Exe jom @("-j$Jobs")
    } finally { Pop-Location }

    return @{ Bin = Join-Path $Bld 'qttools\bin'; Translations = Join-Path $Bld 'qttranslations\translations' }
}

function Test-Package {
    $exes = Get-ChildItem $Stage -Filter *.exe
    foreach ($exe in $exes) {
        $deps = & dumpbin /nologo /dependents $exe.FullName | Out-String
        if ($deps -match '(?im)^\s+(Qt\d\w*|vcruntime\d+\w*|msvcp\d+\w*|ucrtbased?|api-ms-win-crt-[\w-]+)\.dll') {
            throw "$($exe.Name) is not fully static:`n$deps"
        }
    }
    foreach ($tool in 'lrelease', 'lupdate') {
        $out = & (Join-Path $Stage "$tool.exe") -version 2>&1 | Out-String
        if ($out -notmatch [regex]::Escape($Version)) {
            throw "$tool reports the wrong version (expected $Version): $out"
        }
        Write-Host $out.Trim()
    }
}

# --- main ---------------------------------------------------------------------------------

$start = Get-Date
Write-Host "Building Qt Linguist $Version ($Arch) in $WorkDir"

# Strawberry Perl's bundled MinGW (c\bin) ships pkg-config, gcc and OpenSSL headers that
# configure can pick up instead of the MSVC/bundled ones. Perl itself stays on PATH.
$env:Path = ($env:Path -split ';' | Where-Object { $_ -and $_ -notmatch '\\Strawberry\\c\\bin\\?$' }) -join ';'

Enter-Msvc
Get-QtSource
if (Test-Path $Bld) { Remove-Item $Bld -Recurse -Force }
New-Item -ItemType Directory -Force $Bld | Out-Null

$out = if ($IsQt5) { Build-Qt5 } else { Build-Qt6 }

if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $Stage 'translations') | Out-Null

foreach ($t in $ToolNames) {
    $exe = Join-Path $out.Bin "$t.exe"
    if (Test-Path $exe) { Copy-Item $exe $Stage }
}
if (-not (Test-Path (Join-Path $Stage 'linguist.exe'))) { throw "linguist.exe not found in $($out.Bin)" }

$qm = @(Get-ChildItem $out.Translations -Filter *.qm)
if ($qm.Count -eq 0) { throw "No .qm files found in $($out.Translations)" }
$qm | Copy-Item -Destination (Join-Path $Stage 'translations')

# Linguist loads its UI translations from QLibraryInfo::TranslationsPath, which in a static
# build points at the configure -prefix. This makes it resolve to .\translations instead.
# It also needs qt_<lang>.qm (and what that pulls in) next to linguist_<lang>.qm, or it drops
# its own translation, which is why all generated .qm files are shipped.
Set-Content -Path (Join-Path $Stage 'qt.conf') -Value "[Paths]`r`nPrefix = .`r`n" -NoNewline -Encoding ascii

Test-Package

New-Item -ItemType Directory -Force $OutDir | Out-Null
$zip = Join-Path $OutDir "linguist_$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $zip -CompressionLevel Optimal

Write-Host ("Done in {0:hh\:mm\:ss}: {1} ({2:N1} MB)" -f ((Get-Date) - $start), $zip, ((Get-Item $zip).Length / 1MB))
Get-ChildItem $Stage -Filter *.exe | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host "  translations\ ($($qm.Count) .qm files), qt.conf"
