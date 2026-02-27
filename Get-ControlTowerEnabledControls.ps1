<#
.SYNOPSIS
Given a list of AWS Control Catalog control ARNs, report which OUs have them enabled in AWS Control Tower.

.PARAMETER ControlArnFile
Path to a text file containing one Control Catalog ARN per line, e.g.:
  arn:aws:controlcatalog:::control/XXXX
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ControlArnFile
)

$ErrorActionPreference = 'Stop'

Write-Host "Reading catalog control ARNs from: $ControlArnFile" -ForegroundColor Cyan
$inputCatalogArns = Get-Content -Path $ControlArnFile | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() } | Select-Object -Unique

# HashSet for O(1) lookups
$catalogArnSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$null = $inputCatalogArns | ForEach-Object { $catalogArnSet.Add($_) }

# --- Helper: enumerate all OUs recursively
function Get-AllOUs {
    $org = 'organizations'

    $roots = aws $org list-roots --output json | ConvertFrom-Json
    $rootId = $roots.Roots[0].Id

    $queue = @($rootId)
    $allOus = @()

    while ($queue.Count -gt 0) {
        $parent = $queue[0]
        $queue = $queue[1..($queue.Count - 1)] 2>$null

        $nextToken = $null
        do {
            $cmd = @(
                'organizations', 'list-organizational-units-for-parent',
                '--parent-id', $parent,
                '--output', 'json'
            )
            if ($nextToken) { $cmd += @('--starting-token', $nextToken) }

            $resp = aws @cmd | ConvertFrom-Json
            foreach ($ou in $resp.OrganizationalUnits) {
                $allOus += $ou
                # Also enumerate nested OUs
                $queue += $ou.Id
            }
            $nextToken = $resp.NextToken
        } while ($nextToken)
    }

    return $allOus
}

# --- Helper: list enabled controls for a given OU Id (handle pagination)
function Get-EnabledControlsForOu {
    param([Parameter(Mandatory)][string]$OuId)

    $enabled = @()
    $nextToken = $null

    # NOTE: Control Tower expects the OU *ARN* (targetIdentifier). We can derive it, but
    # the CLI also accepts the OU ARN pattern as documented. Safest is to fetch the OU ARN from Organizations 'describe-organizational-unit'.
    $ouDesc = aws organizations describe-organizational-unit --organizational-unit-id $OuId --output json | ConvertFrom-Json
    $ouArn = $ouDesc.OrganizationalUnit.Arn

    do {
        $cmd = @(
            'controltower', 'list-enabled-controls',
            '--target-identifier', $ouArn,
            '--output', 'json'
        )
        if ($nextToken) { $cmd += @('--starting-token', $nextToken) }

        $resp = aws @cmd | ConvertFrom-Json
        if ($resp.enabledControls) {
            $enabled += $resp.enabledControls
        }
        $nextToken = $resp.NextToken
    } while ($nextToken)

    return $enabled
}

# --- Cache: map Control Tower controlIdentifier (regional controltower ARN) -> Control Catalog ARN
$controlIdToCatalogArn = @{}

function Get-CatalogArnFromControlIdentifier {
    param([Parameter(Mandatory)][string]$ControlIdentifierArn)

    if ($controlIdToCatalogArn.ContainsKey($ControlIdentifierArn)) {
        return $controlIdToCatalogArn[$ControlIdentifierArn]
    }

    # controlcatalog get-control accepts either a controltower or controlcatalog ARN and returns catalog ARN format
    # Ref: AWS CLI 'aws controlcatalog get-control' docs
    $gc = aws controlcatalog get-control --control-arn $ControlIdentifierArn --output json | ConvertFrom-Json
    $catalogArn = $gc.Arn
    $controlIdToCatalogArn[$ControlIdentifierArn] = $catalogArn
    return $catalogArn
}

Write-Host "Enumerating Organizational Units..." -ForegroundColor Cyan
$allOus = Get-AllOUs

Write-Host ("Found {0} OUs. Scanning enabled controls..." -f $allOus.Count) -ForegroundColor Green

$resultRows = New-Object System.Collections.Generic.List[object]

foreach ($ou in $allOus) {
    Write-Host ("OU: {0} ({1})" -f $ou.Name, $ou.Id) -ForegroundColor Yellow

    $enabled = Get-EnabledControlsForOu -OuId $ou.Id

    foreach ($ctrl in $enabled) {
        # ctrl.controlIdentifier is a *regional* Control Tower ARN
        $catalogArn = Get-CatalogArnFromControlIdentifier -ControlIdentifierArn $ctrl.controlIdentifier

        if ($catalogArnSet.Contains($catalogArn)) {
            $resultRows.Add([PSCustomObject]@{
                    CatalogControlArn = $catalogArn
                    ControlIdentifier = $ctrl.controlIdentifier
                    EnabledControlArn = $ctrl.arn
                    OUName            = $ou.Name
                    OUId              = $ou.Id
                    # Optional: include drift/status summaries if you want
                    EnablementStatus  = $ctrl.statusSummary.status
                    DriftStatus       = $ctrl.driftStatusSummary.driftStatus
                })
        }
    }
}

if ($resultRows.Count -eq 0) {
    Write-Host "`nNo matches found: None of the provided catalog controls are currently enabled in any OU." -ForegroundColor DarkYellow
}
else {
    Write-Host "`nMatches found:" -ForegroundColor Green
    $resultRows | Sort-Object CatalogControlArn, OUName | Format-Table `
        CatalogControlArn, OUName, OUId, EnablementStatus, DriftStatus -AutoSize
}

# Uncomment to export CSV:
# $out = Join-Path -Path (Get-Location) -ChildPath ("controltower-enabled-from-catalog-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
# $resultRows | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
# Write-Host "CSV exported to: $out" -ForegroundColor Cyan