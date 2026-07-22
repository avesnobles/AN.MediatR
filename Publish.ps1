[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Replace this placeholder with the UNC path of the internal NuGet folder.
    [string]$NuGetSource = '\\<server>\nuget',

    # Perform the irreversible copy to the NuGet source after all validations succeed.
    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = $PSScriptRoot

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

function Get-PackageContentHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $manifest = New-Object System.Text.StringBuilder
        foreach ($entry in $archive.Entries | Sort-Object FullName) {
            $entryHashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
            try {
                $entryStream = $entry.Open()
                try {
                    $entryHash = [System.BitConverter]::ToString($entryHashAlgorithm.ComputeHash($entryStream)).Replace('-', '')
                }
                finally {
                    $entryStream.Dispose()
                }
            }
            finally {
                $entryHashAlgorithm.Dispose()
            }

            [void]$manifest.Append($entry.FullName)
            [void]$manifest.Append('|')
            [void]$manifest.Append($entry.Length)
            [void]$manifest.Append('|')
            [void]$manifest.AppendLine($entryHash)
        }

        $manifestHashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifest.ToString())
            return [System.BitConverter]::ToString($manifestHashAlgorithm.ComputeHash($manifestBytes)).Replace('-', '')
        }
        finally {
            $manifestHashAlgorithm.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PackageArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactsPath,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    $packageNamePattern = '^{0}\.(?<version>\d[^/]*)\.nupkg$' -f [regex]::Escape($PackageId)
    $packageFiles = @(
        Get-ChildItem -LiteralPath $ArtifactsPath -File |
            Where-Object { $_.Name -match $packageNamePattern }
    )

    if ($packageFiles.Count -ne 1) {
        throw "Expected exactly one package for '$PackageId' in '$ArtifactsPath', found $($packageFiles.Count)."
    }

    if ($packageFiles[0].Name -notmatch $packageNamePattern) {
        throw "Unable to resolve the MinVer version from package '$($packageFiles[0].Name)'."
    }

    $packageVersion = $Matches.version
    $symbolsPath = Join-Path $ArtifactsPath ("{0}.{1}.snupkg" -f $PackageId, $packageVersion)
    Assert-PackageExists -Path $symbolsPath

    return [PSCustomObject]@{
        PackageId   = $PackageId
        Version     = $packageVersion
        PackagePath = $packageFiles[0].FullName
        SymbolsPath = $symbolsPath
    }
}

function Copy-PackageToSource {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $destinationPath = Join-Path $DestinationDirectory (Split-Path -Leaf $PackagePath)
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        if ($sourceHash -eq $destinationHash) {
            Write-Host "Already present, skipping $(Split-Path -Leaf $PackagePath)."
            return
        }

        $sourceContentHash = Get-PackageContentHash -Path $PackagePath
        $destinationContentHash = Get-PackageContentHash -Path $destinationPath
        if ($sourceContentHash -eq $destinationContentHash) {
            Write-Host "Already present with equivalent package contents, skipping $(Split-Path -Leaf $PackagePath)."
            return
        }

        throw "A different package with the same name already exists at '$destinationPath'. Source SHA256: $sourceHash. Existing SHA256: $destinationHash."
    }

    Copy-Item -LiteralPath $PackagePath -Destination $destinationPath
}

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is required to resolve the release tag.'
    }

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET SDK is required to build and package the release.'
    }

    if ($NuGetSource -match '^\\\\<[^>]+>\\') {
        throw "NuGetSource still contains a placeholder: '$NuGetSource'. Supply the internal UNC path with -NuGetSource."
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
            # Older tagged releases define Exec with an undeclared $msgs fallback.
            # Keep strict mode for this script, but do not impose it on the build script's child scope.
            Set-StrictMode -Off
            Push-Location -Path $temporaryWorktree
            try {
                & $buildScript
            }
            finally {
                Pop-Location
            }
        }

        $artifactsPath = Join-Path $temporaryWorktree 'artifacts'
        if (-not (Test-Path -LiteralPath $artifactsPath -PathType Container)) {
            throw "The build did not create the artifacts directory: $artifactsPath"
        }

        $packageDefinitions = @(
            'AN.MediatR.Contracts'
            'AN.MediatR'
        )
        $autofacProject = Join-Path $temporaryWorktree 'src\AN.MediatR.Extensions.Autofac.DependencyInjection\AN.MediatR.Extensions.Autofac.DependencyInjection.csproj'
        if (Test-Path -LiteralPath $autofacProject -PathType Leaf) {
            $packageDefinitions += 'AN.MediatR.Extensions.Autofac.DependencyInjection'
        }
        else {
            Write-Warning "Release tag '$($releaseTag.Name)' does not contain AN.MediatR.Extensions.Autofac.DependencyInjection. It will be included automatically when publishing a tag that contains the project."
        }

        $packageArtifacts = @(
            foreach ($packageId in $packageDefinitions) {
                Get-PackageArtifacts -ArtifactsPath $artifactsPath -PackageId $packageId
            }
        )

        $packageVersions = @($packageArtifacts | Select-Object -ExpandProperty Version -Unique)
        if ($packageVersions.Count -ne 1) {
            throw "Package versions calculated by MinVer do not match: $($packageVersions -join ', ')."
        }

        $packageVersion = $packageVersions[0]
        if ($packageVersion -ne $releaseTag.Version) {
            throw "MinVer produced package version '$packageVersion', but release tag '$($releaseTag.Name)' expects '$($releaseTag.Version)'."
        }

        Write-Host 'Generated packages:'
        foreach ($artifact in $packageArtifacts) {
            Write-Host "  $($artifact.PackagePath)"
        }
        foreach ($artifact in $packageArtifacts) {
            Write-Host "  $($artifact.SymbolsPath)"
        }

        if (-not $Publish) {
            Write-Host 'Validation completed. No package was published. Re-run with -Publish to copy the packages to the NuGet source.'
            return
        }

        if (-not (Test-Path -LiteralPath $NuGetSource -PathType Container)) {
            throw "The NuGet source is not available or is not a folder: $NuGetSource"
        }

        $packagesToPublish = @(
            foreach ($artifact in $packageArtifacts) {
                $artifact.PackagePath
            }
            foreach ($artifact in $packageArtifacts) {
                $artifact.SymbolsPath
            }
        )

        $publicationWasSkipped = $false
        foreach ($package in $packagesToPublish) {
            $packageName = Split-Path -Leaf $package
            if ($PSCmdlet.ShouldProcess($NuGetSource, "Publish $packageName")) {
                Write-Host "Publishing $packageName..."
                Copy-PackageToSource -PackagePath $package -DestinationDirectory $NuGetSource
            }
            else {
                $publicationWasSkipped = $true
            }
        }

        if ($publicationWasSkipped) {
            Write-Host 'Publication was not completed because one or more publish operations were skipped.'
        }
        else {
            Write-Host "Release $packageVersion was published to $NuGetSource."
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
