[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers\brain-test-common.ps1')
Assert-BrainTestSandboxActive

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('brain-resolve-' + [guid]::NewGuid().ToString('N'))
$testBrainRoot = Join-Path $testRoot 'brain'
$workspaceRoot = Join-Path $testRoot 'workspace'
# 'Group' sits between the trusted root and the projects so the "ancestor of
# a registered project" rejection (B5) and the "trusted root itself"
# rejection are two distinct, independently verifiable paths.
$groupRoot = Join-Path $workspaceRoot 'Group'
$projectA = Join-Path $groupRoot 'ProjectA'
$projectADeep = Join-Path $projectA 'src\deep'
$projectB = Join-Path $groupRoot 'ProjectB'
$outsideRoot = Join-Path $testRoot 'outside'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Get-Projects {
    $raw = Get-Content -LiteralPath (Join-Path $testBrainRoot 'config\projects.json') -Raw -Encoding UTF8
    return @($raw | ConvertFrom-Json -Depth 20)
}

try {
    New-Item -ItemType Directory -Path $testBrainRoot, $workspaceRoot, $groupRoot, $projectA, $projectADeep, $projectB, $outsideRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testBrainRoot 'config'), (Join-Path $testBrainRoot 'lib'), (Join-Path $testBrainRoot 'templates'), (Join-Path $testBrainRoot 'store\raw'), (Join-Path $testBrainRoot 'integrations') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'brain.ps1') -Destination (Join-Path $testBrainRoot 'brain.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'lib\brain-common.ps1') -Destination (Join-Path $testBrainRoot 'lib\brain-common.ps1')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $testBrainRoot 'VERSION')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'templates\work-record.md') -Destination (Join-Path $testBrainRoot 'templates\work-record.md')
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'integrations\brain-hook.ps1') -Destination (Join-Path $testBrainRoot 'integrations\brain-hook.ps1')
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\projects.json'), "[]`n", [Text.UTF8Encoding]::new($false))
    $trustedConfig = [ordered]@{
        format_version = '0.1'
        trusted_roots = @($workspaceRoot)
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $testBrainRoot 'config\trusted-roots.json'), ($trustedConfig + "`n"), [Text.UTF8Encoding]::new($false))

    $brainScript = Join-Path $testBrainRoot 'brain.ps1'

    # 1. Register ProjectA.
    $registerA = & $brainScript register -ProjectPath $projectA -ProjectId 'project-a'
    Assert-True -Condition ($registerA -match '^REGISTERED ') -Message '1. Registering ProjectA must succeed.'
    Assert-True -Condition ((Get-Projects).Count -eq 1) -Message '1. Registry must have exactly one entry after registering ProjectA.'

    # 2. sync from a subdirectory must create .brain at the project root (B4 fix).
    & $brainScript sync -ProjectPath $projectADeep | Out-Null
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $projectA '.brain\project.json') -PathType Leaf) -Message '2. .brain/project.json must be created at the ProjectA root.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $projectADeep '.brain'))) -Message '2. .brain must NOT be created inside the subdirectory.'

    # 3. Registering the shared parent directory of ProjectA (Group) must fail (B5 fix).
    $parentRejected = $false
    $parentErrorMessage = ''
    try {
        & $brainScript register -ProjectPath $groupRoot 2>$null | Out-Null
    }
    catch {
        $parentRejected = $true
        $parentErrorMessage = $_.Exception.Message
    }
    Assert-True -Condition $parentRejected -Message '3. Registering the parent directory of a registered project must fail.'
    Assert-True -Condition ($parentErrorMessage -match 'project-a') -Message '3. The rejection message must mention the registered project.'
    Assert-True -Condition ((Get-Projects).Count -eq 1) -Message '3. Registry must still have exactly one entry.'

    # 3b. Registering a subdirectory of a registered project must fail too
    # (child direction): one tree must never split across two memories.
    $childDir = Join-Path $projectA 'sub-feature'
    New-Item -ItemType Directory -Path $childDir -Force | Out-Null
    $childRejected = $false
    $childErrorMessage = ''
    try {
        & $brainScript register -ProjectPath $childDir -ProjectId 'project-a-child' 2>$null | Out-Null
    }
    catch {
        $childRejected = $true
        $childErrorMessage = $_.Exception.Message
    }
    Assert-True -Condition $childRejected -Message '3b. Registering a subdirectory of a registered project must fail.'
    Assert-True -Condition ($childErrorMessage -match 'project-a') -Message '3b. The rejection message must mention the registered project.'
    Assert-True -Condition ((Get-Projects).Count -eq 1) -Message '3b. Registry must still have exactly one entry.'

    # 4. Registering the trusted root itself must fail.
    $trustedRejected = $false
    try {
        & $brainScript register -ProjectPath $workspaceRoot -ProjectId 'workspace-as-project' 2>$null | Out-Null
    }
    catch {
        $trustedRejected = $true
    }
    Assert-True -Condition $trustedRejected -Message '4. Registering the trusted root itself must fail.'

    # 5. Registering the BRAIN root itself must fail.
    $brainRootRejected = $false
    $brainRootErrorMessage = ''
    try {
        & $brainScript register -ProjectPath $testBrainRoot 2>$null | Out-Null
    }
    catch {
        $brainRootRejected = $true
        $brainRootErrorMessage = $_.Exception.Message
    }
    Assert-True -Condition $brainRootRejected -Message '5. Registering the BRAIN root itself must fail.'

    # 6. Registering a drive root must fail, and specifically for the drive-root reason.
    $driveRoot = (Split-Path -Qualifier $testRoot) + '\'
    $driveRejected = $false
    $driveErrorMessage = ''
    try {
        & $brainScript register -ProjectPath $driveRoot 2>$null | Out-Null
    }
    catch {
        $driveRejected = $true
        $driveErrorMessage = $_.Exception.Message
    }
    Assert-True -Condition $driveRejected -Message '6. Registering a drive root must fail.'
    Assert-True -Condition ($driveErrorMessage -match 'drive or volume root') -Message '6. The drive-root rejection message must mention "drive or volume root".'
    Assert-True -Condition ($driveErrorMessage -ne $brainRootErrorMessage) -Message '6. The drive-root rejection message must differ from the BRAIN-root rejection message.'

    # 6b. Direct unit-style assertions for the canonicalization contract.
    . (Join-Path $testBrainRoot 'lib\brain-common.ps1')

    $canonicalDriveRoot = Get-BrainCanonicalPath -Path $driveRoot
    Assert-True -Condition ($canonicalDriveRoot.EndsWith('\')) -Message '6b. Get-BrainCanonicalPath of a drive root must end in a trailing separator.'
    Assert-True -Condition ($canonicalDriveRoot -eq [IO.Path]::GetPathRoot($canonicalDriveRoot)) -Message '6b. Get-BrainCanonicalPath of a drive root must equal its own path root.'

    Assert-True -Condition ((Test-BrainPathRoot -Path $canonicalDriveRoot) -eq $true) -Message '6b. Test-BrainPathRoot on a drive root must return true.'
    Assert-True -Condition ((Test-BrainPathRoot -Path $projectA) -eq $false) -Message '6b. Test-BrainPathRoot on a normal directory must return false.'

    $driveRootSomeDir = Join-Path $canonicalDriveRoot 'SomeDir'
    Assert-True -Condition ((Test-BrainPathWithin -Path $driveRootSomeDir -Root $canonicalDriveRoot) -eq $true) -Message '6b. Test-BrainPathWithin of a child of a drive root against that drive root must return true.'

    Assert-True -Condition ((Test-BrainPathWithin -Path $projectA -Root $projectB) -eq $false) -Message '6b. Test-BrainPathWithin of two unrelated normal directories must return false.'

    $withTrailingSep = Get-BrainCanonicalPath -Path 'C:\Foo\Bar\'
    $withoutTrailingSep = Get-BrainCanonicalPath -Path 'C:\Foo\Bar'
    Assert-True -Condition ($withTrailingSep -eq $withoutTrailingSep) -Message '6b. Get-BrainCanonicalPath must be indifferent to a trailing separator on a normal path.'

    # 6c. Direct unit assertion on Get-BrainCanonicalDirectory itself (regression test for the
    # TrimEnd-after-GetFullPath bug that stripped a drive root's trailing separator, turning
    # 'E:\' into the drive-relative string 'E:'). This is independent of the process cwd.
    $canonicalDriveDir = Get-BrainCanonicalDirectory -Path $driveRoot
    Assert-True -Condition ($canonicalDriveDir.EndsWith('\')) -Message '6c. Get-BrainCanonicalDirectory of a drive root must end in a trailing separator.'
    Assert-True -Condition ($canonicalDriveDir -eq [IO.Path]::GetPathRoot($canonicalDriveDir)) -Message '6c. Get-BrainCanonicalDirectory of a drive root must equal its own path root.'

    # 6d. The same checks with the process working directory moved onto the candidate's own drive.
    # Note: a fully qualified drive root ('X:\') is itself cwd-independent, so this does not by
    # itself reproduce the bare-drive-relative failure - test 6e below does that directly. What 6d
    # pins down is that the register path stays correct end to end no matter where the cwd sits.
    $cwdProbeDir = Join-Path $testRoot 'cwd-probe'
    New-Item -ItemType Directory -Path $cwdProbeDir -Force | Out-Null
    $originalLocation = Get-Location
    try {
        Set-Location -LiteralPath $cwdProbeDir

        $canonicalDirWithCwdSet = Get-BrainCanonicalDirectory -Path $driveRoot
        Assert-True -Condition ($canonicalDirWithCwdSet.EndsWith('\')) -Message '6d. Get-BrainCanonicalDirectory of a drive root must end in a trailing separator even when the process cwd sits on the same drive.'
        Assert-True -Condition ($canonicalDirWithCwdSet -eq [IO.Path]::GetPathRoot($canonicalDirWithCwdSet)) -Message '6d. Get-BrainCanonicalDirectory of a drive root must resolve to the drive root, not the process cwd.'

        $canonicalPathWithCwdSet = Get-BrainCanonicalPath -Path $driveRoot
        Assert-True -Condition ($canonicalPathWithCwdSet -eq [IO.Path]::GetPathRoot($canonicalPathWithCwdSet)) -Message '6d. Get-BrainCanonicalPath of a drive root must resolve to the drive root, not the process cwd.'

        Assert-True -Condition ((Test-BrainPathRoot -Path $canonicalDirWithCwdSet) -eq $true) -Message '6d. Test-BrainPathRoot on the canonicalized drive root must return true even when the process cwd sits on the same drive.'

        # Reproduce the exact register path from brain.ps1: Get-BrainCanonicalDirectory feeding into Test-BrainProjectRegistrable.
        $registerViaScriptSucceeded = $false
        $registerErrorMessage = ''
        try {
            & $brainScript register -ProjectPath $driveRoot 2>$null | Out-Null
            $registerViaScriptSucceeded = $true
        }
        catch {
            $registerErrorMessage = $_.Exception.Message
        }
        Assert-True -Condition (-not $registerViaScriptSucceeded) -Message '6d. Registering a drive root must still fail when the process cwd sits on that same drive.'
        Assert-True -Condition ($registerErrorMessage -match 'drive or volume root') -Message '6d. The drive-root rejection message must still be produced when the process cwd sits on that same drive.'
    }
    finally {
        Set-Location -LiteralPath $originalLocation
    }

    # 6e. Direct demonstration of WHY a drive root must never be trimmed, and a static regression
    # guard for the bootstrap path in brain.ps1. A bare drive-relative string such as 'X:' really is
    # resolved against the process's per-drive current directory, and that information loss cannot be
    # undone by canonicalizing again later - so no BRAIN code may ever produce one.
    $driveQualifier = Split-Path -Qualifier $driveRoot
    $bareDriveProbeDir = Join-Path $testRoot 'bare-drive-probe'
    New-Item -ItemType Directory -Path $bareDriveProbeDir -Force | Out-Null
    $locationBeforeBareProbe = Get-Location
    $netCurrentDirectoryBeforeBareProbe = [Environment]::CurrentDirectory
    try {
        # Set-Location moves the PowerShell provider location but does NOT update the .NET current
        # directory that [IO.Path]::GetFullPath consults, so set both to make this deterministic.
        Set-Location -LiteralPath $bareDriveProbeDir
        [Environment]::CurrentDirectory = $bareDriveProbeDir
        $bareResolved = [IO.Path]::GetFullPath($driveQualifier)
        Assert-True -Condition ($bareResolved -ne [IO.Path]::GetPathRoot($driveRoot)) -Message '6e. A bare drive-relative string must be shown to resolve away from the drive root, proving the trim is destructive.'
        Assert-True -Condition ((Get-BrainCanonicalPath -Path $driveRoot) -ne $driveQualifier) -Message '6e. Get-BrainCanonicalPath must never reduce a drive root to a bare drive qualifier.'
        Assert-True -Condition ((Get-BrainCanonicalDirectory -Path $driveRoot) -ne $driveQualifier) -Message '6e. Get-BrainCanonicalDirectory must never reduce a drive root to a bare drive qualifier.'
    }
    finally {
        Set-Location -LiteralPath $locationBeforeBareProbe
        [Environment]::CurrentDirectory = $netCurrentDirectoryBeforeBareProbe
    }

    # brain.ps1 computes $BrainRoot before it can dot-source the library, so that one line cannot use
    # Get-BrainCanonicalPath. It must therefore not trim at all: trimming there would produce exactly
    # the bare drive-relative string proven destructive above, and re-canonicalizing afterwards cannot
    # recover it. Guard that line statically, since it is unreachable from a temp-directory fixture.
    $brainScriptText = Get-Content -LiteralPath $brainScript -Raw -Encoding UTF8
    Assert-True -Condition ($brainScriptText -notmatch [regex]::Escape('GetFullPath($PSScriptRoot).TrimEnd')) -Message '6e. brain.ps1 must not trim the script root before the library is dot-sourced.'

    # 7. Register ProjectB; workspace parent must still fail and name one of the projects.
    $registerB = & $brainScript register -ProjectPath $projectB -ProjectId 'project-b'
    Assert-True -Condition ($registerB -match '^REGISTERED ') -Message '7. Registering ProjectB must succeed.'
    $parentRejectedAgain = $false
    $parentErrorMessageAgain = ''
    try {
        & $brainScript register -ProjectPath $groupRoot -ProjectId 'group-again' 2>$null | Out-Null
    }
    catch {
        $parentRejectedAgain = $true
        $parentErrorMessageAgain = $_.Exception.Message
    }
    Assert-True -Condition $parentRejectedAgain -Message '7. Registering the shared parent directory must still fail after ProjectB registration.'
    Assert-True -Condition ($parentErrorMessageAgain -match 'project-a' -or $parentErrorMessageAgain -match 'project-b') -Message '7. The rejection message must name one of the registered projects.'

    # 8. An unregistered directory outside the workspace must be rejected by init.
    $outsideRejected = $false
    try {
        & $brainScript init -ProjectPath $outsideRoot 2>$null | Out-Null
    }
    catch {
        $outsideRejected = $true
    }
    Assert-True -Condition $outsideRejected -Message '8. init on an unregistered outside directory must be rejected.'

    [pscustomobject]@{
        result = 'PASS'
        project_a_registered = $true
        subdirectory_sync_creates_root_brain = $true
        parent_registration_rejected = $true
        trusted_root_registration_rejected = $true
        brain_root_registration_rejected = $true
        drive_root_registration_rejected = $true
        parent_registration_still_rejected_after_b = $true
        outside_directory_rejected = $true
    } | ConvertTo-Json -Depth 6
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).Path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $safeName = (Split-Path -Leaf $resolved) -match '^brain-resolve-[0-9a-f]{32}$'
        $insideTemp = $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)
        if (-not ($safeName -and $insideTemp)) {
            throw "Refusing to clean unsafe project-resolution test path: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
