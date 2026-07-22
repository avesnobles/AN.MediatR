[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Replace this placeholder with the UNC path of the internal NuGet folder.
    [string]$NuGetSource = '\\(server_ip)\nuget',

    # Perform the irreversible copy to the NuGet source after all validations succeed.
    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = $PSScriptRoot
$placeholderSource = '\\(server_ip)\nuget'

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$ErrorMessage
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
}

function Get-LatestStableReleaseTag {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)

    $tags = & git -C $RepositoryPath for-each-ref --merged=HEAD --sort=-creatordate --format='%(refname:short)' refs/tags
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read Git tags from the repository.'
    }

    foreach ($tag in $tags) {
        if ($tag -match '^v(?<version>\d+\.\d+\.\d+)$') {
            return [PSCustomObject]@{
                Name    = $tag
                Version = $Matches.version
            }
        }
    }

    throw 'No reachable stable release tag was found. Create an annotated tag in the form vMAJOR.MINOR.PATCH first.'
}

function Assert-CleanWorkingTree {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)

    $changes = & git -C $RepositoryPath status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the Git working-tree status.'
    }

    if ($changes) {
        throw 'The working tree is not clean. Commit, stash, or remove local changes before publishing a tagged release.'
    }
}

function Assert-PackageExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected package was not generated: $Path"
    }
}

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is required to resolve the release tag.'
    }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET SDK is required to build and package the release.'
    }

    if ($NuGetSource -eq $placeholderSource) {
        throw "NuGetSource still contains the placeholder '$placeholderSource'. Supply the internal UNC path with -NuGetSource."
    }

    Assert-CleanWorkingTree -RepositoryPath $repositoryRoot

    $releaseTag = Get-LatestStableReleaseTag -RepositoryPath $repositoryRoot
    $tagCommit = (& git -C $repositoryRoot rev-list -n 1 $releaseTag.Name).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tagCommit)) {
        throw "Unable to resolve commit for tag '$($releaseTag.Name)'."
    }

    $temporaryWorktree = Join-Path ([System.IO.Path]::GetTempPath()) ("AN.MediatR-release-{0}-{1}" -f $releaseTag.Version, [Guid]::NewGuid().ToString('N'))

    Write-Host "Release tag: $($releaseTag.Name) ($tagCommit)"
    Write-Host "Package version expected: $($releaseTag.Version)"
    Write-Host "NuGet source: $NuGetSource"

    Invoke-ExternalCommand -ErrorMessage "Unable to create a temporary worktree for tag '$($releaseTag.Name)'." -Command {
        git -C $repositoryRoot worktree add --detach $temporaryWorktree $releaseTag.Name
    }

    try {
        $buildScript = Join-Path $temporaryWorktree 'Build.ps1'
        if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
            throw "Build.ps1 was not found in tag '$($releaseTag.Name)'."
        }

        Write-Host 'Building, testing, and packing the exact tagged source...'
        Invoke-ExternalCommand -ErrorMessage 'Build, test, or pack failed. No packages were published.' -Command {
            & $buildScript
        }

        $artifactsPath = Join-Path $temporaryWorktree 'artifacts'
        $contractsPackage = Join-Path $artifactsPath ("AN.MediatR.Contracts.{0}.nupkg" -f $releaseTag.Version)
        $mainPackage = Join-Path $artifactsPath ("AN.MediatR.{0}.nupkg" -f $releaseTag.Version)
        $contractsSymbols = Join-Path $artifactsPath ("AN.MediatR.Contracts.{0}.snupkg" -f $releaseTag.Version)
        $mainSymbols = Join-Path $artifactsPath ("AN.MediatR.{0}.snupkg" -f $releaseTag.Version)

        Assert-PackageExists -Path $contractsPackage
        Assert-PackageExists -Path $mainPackage
        Assert-PackageExists -Path $contractsSymbols
        Assert-PackageExists -Path $mainSymbols

        Write-Host 'Generated packages:'
        Write-Host "  $contractsPackage"
        Write-Host "  $mainPackage"
        Write-Host "  $contractsSymbols"
        Write-Host "  $mainSymbols"

        if (-not $Publish) {
            Write-Host 'Validation completed. No package was published. Re-run with -Publish to copy the packages to the NuGet source.'
            return
        }

        if (-not (Test-Path -LiteralPath $NuGetSource -PathType Container)) {
            throw "The NuGet source is not available or is not a folder: $NuGetSource"
        }

        $packagesToPublish = @(
            $contractsPackage,
            $mainPackage,
            $contractsSymbols,
            $mainSymbols
        )

        $publicationWasSkipped = $false
        foreach ($package in $packagesToPublish) {
            $packageName = Split-Path -Leaf $package
            if ($PSCmdlet.ShouldProcess($NuGetSource, "Publish $packageName")) {
                Write-Host "Publishing $packageName..."
                Invoke-ExternalCommand -ErrorMessage "Failed to publish '$packageName'." -Command {
                    dotnet nuget push $package --source $NuGetSource --skip-duplicate
                }
            }
            else {
                $publicationWasSkipped = $true
            }
        }

        if ($publicationWasSkipped) {
            Write-Host 'Publication was not completed because one or more publish operations were skipped.'
        }
        else {
            Write-Host "Release $($releaseTag.Version) was published to $NuGetSource."
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryWorktree) {
            Write-Host 'Removing temporary release worktree...'
            & git -C $repositoryRoot worktree remove --force $temporaryWorktree
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Unable to remove temporary worktree: $temporaryWorktree"
            }
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
