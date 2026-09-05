[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-sandbox-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$dummyLiveRoot = Join-Path $testRoot 'dummy-live-root'
$dummyMissingRoot = Join-Path $testRoot 'dummy-missing-root'
$escapeHatch = Join-Path ([IO.Path]::GetTempPath()) ('brain-escape-hatch-' + [guid]::NewGuid().ToString('N'))
$setupScript = Join-Path $sourceRoot 'integrations\brain-setup.ps1'
$hookScript = Join-Path $sourceRoot 'integrations\brain-hook.ps1'
$providersDir = Join-Path $sourceRoot 'integrations\providers'
$dummyHookFile = Join-Path $providersDir 'zz-dummy-probe.ps1'
$dummyPluginFile = Join-Path $providersDir 'zz-dummy-plugin.ps1'
$dummyTemplateFile = Join-Path $providersDir 'zz-dummy.brain-plugin.txt'
$realProjectsHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash
# Live installs are legitimate: pin pre-test hashes (or absence) for real
# user files this suite must not disturb, and require them unchanged below.
$realCursorHooksPath = Join-Path $env:USERPROFILE '.cursor\hooks.json'
$realCursorHooksBefore = if (Test-Path -LiteralPath $realCursorHooksPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $realCursorHooksPath -Algorithm SHA256).Hash
}
else {
    $null
}
$realPluginCheckPath = Join-Path $env:USERPROFILE '.config\opencode\plugins\brain.js'
$realPluginBefore = if (Test-Path -LiteralPath $realPluginCheckPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $realPluginCheckPath -Algorithm SHA256).Hash
}
else {
    $null
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Remove-DummyFiles {
    foreach ($file in @($dummyHookFile, $dummyPluginFile, $dummyTemplateFile)) {
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force
        }
    }
}

try {
    New-Item -ItemType Directory -Path $testBrainRoot, $dummyLiveRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    Remove-DummyFiles

    . (Join-Path $sourceRoot 'lib\brain-integrations.ps1')

    # === 1. Guard unit semantics (fail-closed, fail-open only when gate is off) ===
    $outsidePath = Join-Path ([IO.Path]::GetTempPath()) 'definitely-outside-sandbox.txt'
    $insidePath = Join-Path $env:BRAIN_TEST_SANDBOX 'inside.txt'
    $threw = $false
    try {
        Assert-BrainSandboxWriteAllowed -Path $outsidePath -Provenance 'resolved'
    }
    catch {
        $threw = ([string]$_.Exception.Message -match 'TEST SAFETY VIOLATION')
    }
    Assert-True -Condition $threw -Message '1. Resolved writes outside the sandbox must throw TEST SAFETY VIOLATION.'
    Assert-BrainSandboxWriteAllowed -Path $outsidePath -Provenance 'explicit'
    Assert-BrainSandboxWriteAllowed -Path $insidePath -Provenance 'resolved'
    $savedGate = $env:BRAIN_TEST_SANDBOX
    try {
        $env:BRAIN_TEST_SANDBOX = ''
        Assert-BrainSandboxWriteAllowed -Path $outsidePath -Provenance 'resolved'
    }
    finally {
        $env:BRAIN_TEST_SANDBOX = $savedGate
    }

    # === 2. Temp-SetupRoot discovery of future-style definitions ===
    $fakeSetup = Join-Path $testRoot 'fakesetup'
    $fakeProviders = Join-Path $fakeSetup 'integrations\providers'
    New-Item -ItemType Directory -Path $fakeProviders -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeProviders 'zzfuture.ps1'), "@{ Id = 'zzfuture'; Name = 'ZZFuture'; ConfigRoots = @('C:\\nope-zz-missing', '$($dummyLiveRoot -replace '\\', '\\')') }`n", [Text.UTF8Encoding]::new($false))
    $discovered = @(Get-BrainIntegrationDefinitions -SetupRoot $fakeSetup)
    Assert-True -Condition ((@($discovered | ForEach-Object { [string]$_.Id }) -contains 'zzfuture')) -Message '2. Future provider file must be auto-discovered.'
    $futureDef = Get-BrainIntegration -Definitions $discovered -Id 'zzfuture'
    Assert-True -Condition ((Resolve-BrainIntegrationRoot -Definition $futureDef) -eq $dummyLiveRoot) -Message '2. First existing ConfigRoot must win.'

    # === 3. End-to-end dummy integrations with NO path overrides ===
    # This is the crux: every path argument a test could forget is omitted.
    # Only -BrainRoot (temp) and -Integration are given; the gate must force
    # all targets below the sandbox.
    $dummyHookDef = "@{ Id = 'zzdummyhook'; Name = 'ZZDummyHook'; DisplayName = 'ZZ Dummy Hook'; ArtifactKind = 'HookJson'; HookSchema = 'CursorFlat'; ConfigRoots = @('$($dummyLiveRoot -replace '\\', '\\')', '$($dummyMissingRoot -replace '\\', '\\')'); ConfigFileName = 'zzdummy.json'; HandlerStyle = 'FlatCommand'; HookIdPrefix = 'brain.zzdummyhook.'; StatusPrefix = 'BRAIN ZZDummyHook '; StopStyle = 'HookSpecific'; SessionIdFields = @('session_id'); CwdFields = @('cwd'); Capabilities = @{ Install = `$true; Repair = `$true; Uninstall = `$true }; Events = @( @{ EventName = 'sessionStart'; Matcher = ''; Timeout = 5 } ) }`n"
    [IO.File]::WriteAllText($dummyHookFile, $dummyHookDef, [Text.UTF8Encoding]::new($false))
    $dummyTemplate = "// managed by BRAIN (brain.zzdummyplugin)`n// template `"__BRAIN_ROOT__`" `"__BRAIN_HOOK_PATH__`" `"__BRAIN_PWSH_PATH__`"`n"
    [IO.File]::WriteAllText($dummyTemplateFile, $dummyTemplate, [Text.UTF8Encoding]::new($false))
    $dummyPluginDef = "@{ Id = 'zzdummyplugin'; Name = 'ZZDummyPlugin'; DisplayName = 'ZZ Dummy Plugin'; ArtifactKind = 'PluginFile'; PluginFileName = 'zzdummy.js'; PluginTemplateFile = 'zz-dummy.brain-plugin.txt'; PluginManagedMarker = '// managed by BRAIN (brain.zzdummyplugin)'; ConfigRoots = @('$($dummyLiveRoot -replace '\\', '\\')'); HandlerStyle = 'PluginBridge'; HookIdPrefix = 'brain.zzdummyplugin.'; StatusPrefix = 'BRAIN ZZDummyPlugin '; StopStyle = 'HookSpecific'; Capabilities = @{ Install = `$true; Repair = `$true; Uninstall = `$true }; Events = @() }`n"
    [IO.File]::WriteAllText($dummyPluginFile, $dummyPluginDef, [Text.UTF8Encoding]::new($false))

    $listAll = & $setupScript -Action Integrations -BrainRoot $testBrainRoot -BrainHookPath $hookScript | ConvertFrom-Json -Depth 30
    $allIds = @($listAll.integrations | ForEach-Object { [string]$_.id })
    Assert-True -Condition ($allIds -contains 'zzdummyhook' -and $allIds -contains 'zzdummyplugin') -Message '3. Dummy integrations must be auto-listed with zero Core changes.'

    $hookInstall = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration zzdummyhook | ConvertFrom-Json -Depth 30
    $expectedHook = Join-Path $env:BRAIN_TEST_SANDBOX 'zzdummyhook.hooks.json'
    Assert-True -Condition (Test-Path -LiteralPath $expectedHook -PathType Leaf) -Message '3. Forgotten-argument Install must land inside the sandbox.'
    Assert-True -Condition (@(Get-ChildItem -LiteralPath $dummyLiveRoot -File -ErrorAction SilentlyContinue).Count -eq 0) -Message '3. The existing dummy ConfigRoot must stay untouched.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $dummyMissingRoot)) -Message '3. The missing dummy ConfigRoot must not be created.'
    $pluginInstall = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration zzdummyplugin | ConvertFrom-Json -Depth 30
    $expectedPlugin = Join-Path $env:BRAIN_TEST_SANDBOX 'zzdummy.js'
    Assert-True -Condition (Test-Path -LiteralPath $expectedPlugin -PathType Leaf) -Message '3. Dummy plugin must land inside the sandbox.'
    Assert-True -Condition ((Get-Content -LiteralPath $expectedPlugin -Raw -Encoding UTF8).StartsWith('// managed by BRAIN (brain.zzdummyplugin)')) -Message '3. Dummy plugin must carry its marker.'
    $null = & $setupScript -Action Uninstall -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration zzdummyhook | ConvertFrom-Json -Depth 30
    $null = & $setupScript -Action Uninstall -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration zzdummyplugin | ConvertFrom-Json -Depth 30
    $afterHookUninstall = Get-Content -LiteralPath $expectedHook -Raw -Encoding UTF8
    Assert-True -Condition ($afterHookUninstall -notmatch 'brain-hook\.ps1') -Message '3. Uninstall must remove managed hook entries.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $expectedPlugin)) -Message '3. Uninstall must delete the sandbox plugin file.'

    # === 4. §7 regression injection: corrupt the forcing seam ===
    # The guard reads $env directly, so even a broken forcing layer must be
    # caught pre-write (never "written first, canary later").
    $libPath = Join-Path $sourceRoot 'lib\brain-integrations.ps1'
    $libBefore = Get-Content -LiteralPath $libPath -Raw -Encoding UTF8
    $libHashBefore = (Get-FileHash -LiteralPath $libPath -Algorithm SHA256).Hash
    $seam = 'return ([string]$env:BRAIN_TEST_SANDBOX).Trim()'
    $occurrences = @([regex]::Matches($libBefore, [regex]::Escape($seam))).Count
    Assert-True -Condition ($occurrences -eq 1) -Message '4. Injection seam must be unique.'
    try {
        [IO.File]::WriteAllText($libPath, ($libBefore.Replace($seam, "return '$escapeHatch'")), [Text.UTF8Encoding]::new($false))
        $injectedThrew = $false
        try {
            $null = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration zzdummyhook | ConvertFrom-Json -Depth 30
        }
        catch {
            $injectedThrew = ([string]$_.Exception.Message -match 'TEST SAFETY VIOLATION')
        }
        Assert-True -Condition $injectedThrew -Message '4. Corrupted forcing must be stopped pre-write by the guard.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $escapeHatch)) -Message '4. The escape target must never be created.'
    }
    finally {
        [IO.File]::WriteAllText($libPath, $libBefore, [Text.UTF8Encoding]::new($false))
    }
    Assert-True -Condition ((Get-FileHash -LiteralPath $libPath -Algorithm SHA256).Hash -eq $libHashBefore) -Message '4. Library must be byte-identical after restore.'
    $recovered = & $setupScript -Action Install -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration zzdummyhook | ConvertFrom-Json -Depth 30
    Assert-True -Condition (Test-Path -LiteralPath $expectedHook -PathType Leaf) -Message '4. Setup must work again after restore.'
    $null = & $setupScript -Action Uninstall -BrainRoot $testBrainRoot -BrainHookPath $hookScript -Integration zzdummyhook | ConvertFrom-Json -Depth 30

    # === 5. BrainRoot default guard + hook guard ===
    # Only Enable/Disable write below the BrainRoot, so only they refuse the
    # shipped root in test mode; target-writing actions are covered by §4.
    $mutatingGuardThrew = $false
    try {
        $null = & $setupScript -Action Enable -Integration codex 2>&1
    }
    catch {
        $mutatingGuardThrew = ([string]$_.Exception.Message -match 'TEST SAFETY VIOLATION')
    }
    Assert-True -Condition $mutatingGuardThrew -Message '5. BrainRoot-writing actions must refuse the shipped root in test mode.'
    $hookGuard = '{"hook_event_name":"stop","session_id":"x","cwd":"C:\\"}' | & (Get-Command pwsh.exe -ErrorAction Stop).Source -NoProfile -NonInteractive -File $hookScript -Provider Cursor 2>&1
    Assert-True -Condition ($LASTEXITCODE -eq 3) -Message '5. Hook without -BrainRoot must fail closed in test mode.'

    # === 6. Real user data untouched ===
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $sourceRoot 'config\projects.json') -Algorithm SHA256).Hash -eq $realProjectsHash) -Message '6. Real config/projects.json must be untouched.'
    if ($null -eq $realCursorHooksBefore) {
        Assert-True -Condition (-not (Test-Path -LiteralPath $realCursorHooksPath)) -Message '6. No real Cursor hooks may exist.'
    }
    else {
        Assert-True -Condition ((Get-FileHash -LiteralPath $realCursorHooksPath -Algorithm SHA256).Hash -eq $realCursorHooksBefore) -Message '6. Real Cursor hooks.json must be untouched.'
    }
    $realPluginPath = $realPluginCheckPath
    if ($null -eq $realPluginBefore) {
        Assert-True -Condition (-not (Test-Path -LiteralPath $realPluginPath)) -Message '6. No real OpenCode plugin may exist.'
    }
    else {
        Assert-True -Condition ((Get-FileHash -LiteralPath $realPluginPath -Algorithm SHA256).Hash -eq $realPluginBefore) -Message '6. Real OpenCode plugin file must be untouched.'
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'config\integrations.json'))) -Message '6. No integrations.json may be created in the real BRAIN root.'

    # === 7. Canary watches the REAL repository root, not tests/ ===
    $canaryRoots = @(Get-BrainTestCanaryRoots | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $expectedConfig = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'config'))
    $expectedRaw = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'store\raw'))
    $expectedHelper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'helpers'))
    Assert-True -Condition ($canaryRoots -contains $expectedConfig) -Message '7. Canary must watch the real BRAIN/config.'
    Assert-True -Condition ($canaryRoots -contains $expectedRaw) -Message '7. Canary must watch the real BRAIN/store/raw.'
    Assert-True -Condition (-not ($canaryRoots -contains ([IO.Path]::GetFullPath((Join-Path $expectedHelper '..\\config'))))) -Message '7. Canary must not watch tests/config.'
    Assert-True -Condition ((New-BrainTestCanary).Entries.Count -gt 0) -Message '7. Canary snapshot must not be empty.'
    # Derived roots: every declared ConfigRoots entry of every discovered
    # definition must be watched, so provider N+1 needs no helper edit.
    . (Join-Path $sourceRoot 'lib\brain-integrations.ps1')
    $discoveredDefinitions = @(Get-BrainIntegrationDefinitions -SetupRoot $sourceRoot)
    Assert-True -Condition ($discoveredDefinitions.Count -ge 6) -Message '7. Registry must discover all shipped integrations.'
    foreach ($definition in $discoveredDefinitions) {
        try {
            $declared = @($definition.ConfigRoots)
        }
        catch {
            $declared = @()
        }
        foreach ($entry in $declared) {
            $text = ([string]$entry).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($text.StartsWith('~/') -or $text.StartsWith('~\') -or $text -eq '~') {
                $text = $env:USERPROFILE + $text.Substring(1)
            }
            $text = [Environment]::ExpandEnvironmentVariables($text)
            try {
                $expanded = [IO.Path]::GetFullPath($text)
            }
            catch {
                continue
            }
            Assert-True -Condition ($canaryRoots -contains $expanded) -Message ("7. Declared ConfigRoots must be watched: $expanded")
        }
    }

    [pscustomobject][ordered]@{
        result = 'PASS'
        guard_unit_ok = $true
        discovery_ok = $true
        dummy_e2e_ok = $true
        injection_caught_prewrite = $true
        root_guards_ok = $true
        real_user_data_untouched = $true
        canary_roots_ok = $true
    } | ConvertTo-Json -Depth 10
}
finally {
    Remove-DummyFiles
    if ((Test-Path -LiteralPath $dummyHookFile) -or (Test-Path -LiteralPath $dummyPluginFile) -or (Test-Path -LiteralPath $dummyTemplateFile)) {
        throw 'Dummy integration files were not fully removed from the production registry.'
    }
    if (Test-Path -LiteralPath $escapeHatch) {
        Remove-Item -LiteralPath $escapeHatch -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-sandbox-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe sandbox test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
