# Taken from psake https://github.com/psake/psake

<#
.SYNOPSIS
  This is a helper function that runs a scriptblock and checks the PS variable $lastexitcode
  to see if an error occcured. If an error is detected then an exception is thrown.
  This function allows you to run command-line programs without having to
  explicitly check the $lastexitcode variable.
.EXAMPLE
  exec { svn info $repository_trunk } "Error executing SVN. Please verify SVN command-line client is installed"
#>
function Exec
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0,Mandatory=1)][scriptblock]$cmd,
        [Parameter(Position=1,Mandatory=0)][string]$errorMessage = "Error executing command: $cmd"
    )
    & $cmd
    if ($lastexitcode -ne 0) {
        throw ("Exec: " + $errorMessage)
    }
}

$repositoryRoot = $PSScriptRoot
$artifacts = Join-Path $repositoryRoot "artifacts"
$solution = Join-Path $repositoryRoot "AN.MediatR.sln"
$mainProject = Join-Path $repositoryRoot "src\AN.MediatR\AN.MediatR.csproj"
$contractsProject = Join-Path $repositoryRoot "src\AN.MediatR.Contracts\AN.MediatR.Contracts.csproj"
$autofacProject = Join-Path $repositoryRoot "src\AN.MediatR.Extensions.Autofac.DependencyInjection\AN.MediatR.Extensions.Autofac.DependencyInjection.csproj"
$projectsToPack = @(
    $mainProject
    $contractsProject
    $autofacProject
)

if(Test-Path $artifacts) { Remove-Item $artifacts -Force -Recurse }

Push-Location $repositoryRoot
try {
    exec { & dotnet clean $solution -c Release }

    exec { & dotnet build $solution -c Release }

    exec { & dotnet test $solution -c Release --no-build -l trx --verbosity=normal }

    foreach ($project in $projectsToPack) {
        exec { & dotnet pack $project -c Release -o $artifacts --no-build }
    }
}
finally {
    Pop-Location
}
