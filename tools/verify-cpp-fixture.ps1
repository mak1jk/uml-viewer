param(
  [string]$ClangUmlPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$fixtureSource = Join-Path $repoRoot "examples\cpp-fixture"
$targetRoot = Join-Path $repoRoot "target"
$runRoot = Join-Path $targetRoot ("cpp-fixture-verify-" + [Guid]::NewGuid().ToString("N"))
$buildDir = Join-Path $runRoot "build"
$outputDir = Join-Path $runRoot "output"

if (-not $ClangUmlPath) {
  $command = Get-Command clang-uml -ErrorAction SilentlyContinue
  if ($command) { $ClangUmlPath = $command.Source }
  else {
    $localInstall = Join-Path $env:LOCALAPPDATA "Apps\clang-uml\bin\clang-uml.exe"
    if (Test-Path -LiteralPath $localInstall) { $ClangUmlPath = $localInstall }
  }
}
if (-not $ClangUmlPath -or -not (Test-Path -LiteralPath $ClangUmlPath)) {
  throw "clang-uml was not found. Install it or pass -ClangUmlPath."
}
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
  throw "MSVC cl.exe is not on PATH. Run this script in Developer PowerShell for VS 2022."
}
foreach ($tool in @("cmake", "ninja", "clj")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool was not found on PATH."
  }
}

New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $fixtureSource "CMakeLists.txt") -Destination $runRoot
Copy-Item -LiteralPath (Join-Path $fixtureSource ".clang-uml") -Destination $runRoot
Copy-Item -LiteralPath (Join-Path $fixtureSource "include") -Destination $runRoot -Recurse
Copy-Item -LiteralPath (Join-Path $fixtureSource "src") -Destination $runRoot -Recurse

$configPath = Join-Path $runRoot ".clang-uml"
$config = Get-Content -LiteralPath $configPath -Raw
$config = $config.Replace("../../target/cpp-fixture-build", $buildDir.Replace("\", "/"))
$config = $config.Replace("../../target/cpp-fixture-output", $outputDir.Replace("\", "/"))
[IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))

function Invoke-Checked {
  param([string]$Program, [string[]]$Arguments)
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Program exited with code $LASTEXITCODE"
  }
}

function Build-And-Extract {
  Invoke-Checked "cmake" @("-S", $runRoot, "-B", $buildDir, "-G", "Ninja",
    "-DCMAKE_CXX_COMPILER=cl", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")
  Invoke-Checked "cmake" @("--build", $buildDir)
  Push-Location $runRoot
  try {
    Invoke-Checked $ClangUmlPath @("-c", ".clang-uml", "-n", "cpp_fixture", "-g", "json")
  }
  finally { Pop-Location }
}

function Convert-And-Verify {
  param([string]$OutputFile, [switch]$NoDependency)
  $jsonFile = Join-Path $outputDir "cpp_fixture.json"
  $flags = if ($NoDependency) { @("--no-dependency") } else { @("--verify-fixture") }
  Invoke-Checked "clj" (@("-M:cpp-ir", $jsonFile, $OutputFile, $runRoot) + $flags)
}

function Get-Sha256 {
  param([string]$Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($Path)
  try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "") }
  finally {
    $stream.Dispose()
    $sha.Dispose()
  }
}

Write-Host "Working copy: $runRoot"
$controller = Join-Path $runRoot "include\app\controller.hpp"
$originalController = [IO.File]::ReadAllText($controller)
$implementation = Join-Path $runRoot "src\fixture.cpp"
$originalImplementation = [IO.File]::ReadAllText($implementation)
$withoutDependency = [Regex]::Replace(
  $originalController,
  '(?m)^[ \t]*store::Node resolve\([^\r\n]*\)[^\r\n]*;\r?\n',
  "")
$implementationWithoutDependency = [Regex]::Replace(
  $originalImplementation,
  '(?s)\r?\nstore::Node app::Controller::resolve\([^)]*\) const \{\r?\n  return value;\r?\n\}\r?\n?$',
  "`n")
if ($withoutDependency -eq $originalController) {
  throw "Could not find the fixture's resolve(store::Node) dependency declaration."
}
if ($implementationWithoutDependency -eq $originalImplementation) {
  throw "Could not find the fixture's resolve(store::Node) dependency definition."
}

# Begin without the store dependency, add it, remove it, then restore the source.
[IO.File]::WriteAllText($controller, $withoutDependency, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($implementation, $implementationWithoutDependency, [Text.UTF8Encoding]::new($false))
Build-And-Extract
$removedEdn = Join-Path $outputDir "without-dependency.edn"
Convert-And-Verify $removedEdn -NoDependency

[IO.File]::WriteAllText($controller, $originalController, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($implementation, $originalImplementation, [Text.UTF8Encoding]::new($false))
Build-And-Extract
$withDependencyEdn = Join-Path $outputDir "cpp_fixture.edn"
Convert-And-Verify $withDependencyEdn
$firstHash = Get-Sha256 $withDependencyEdn

$repeatEdn = Join-Path $outputDir "repeat.edn"
Convert-And-Verify $repeatEdn
$repeatHash = Get-Sha256 $repeatEdn
if ($firstHash -ne $repeatHash) {
  throw "Repeated conversion produced different EDN: $firstHash != $repeatHash"
}

[IO.File]::WriteAllText($controller, $withoutDependency, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($implementation, $implementationWithoutDependency, [Text.UTF8Encoding]::new($false))
Build-And-Extract
Convert-And-Verify $withDependencyEdn -NoDependency

[IO.File]::WriteAllText($controller, $originalController, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($implementation, $originalImplementation, [Text.UTF8Encoding]::new($false))
Build-And-Extract
Convert-And-Verify $withDependencyEdn
$finalHash = Get-Sha256 $withDependencyEdn
if ($firstHash -ne $finalHash) {
  throw "Restoring the original fixture changed the generated EDN hash."
}

Write-Host "PASS: real clang-uml extraction, conversion, class/edge/location assertions, dependency removal/addition, and repeatability."
Write-Host "Viewer input: $withDependencyEdn"
Write-Host "SHA256: $finalHash"
