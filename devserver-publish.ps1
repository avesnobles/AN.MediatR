[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        $address = $null
        if (-not [System.Net.IPAddress]::TryParse($_, [ref]$address) -or
            $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw 'Server must be a valid IPv4 address.'
        }

        $true
    })]
    [string]$Server,

    [switch]$WhatIf
)

$nuGetSource = '\\{0}\nuget' -f $Server
$publishParameters = @{
    NuGetSource = $nuGetSource
    Publish = $true
    Confirm = $false
}

if ($WhatIf) {
    $publishParameters.WhatIf = $true
}

& (Join-Path $PSScriptRoot 'Publish.ps1') @publishParameters