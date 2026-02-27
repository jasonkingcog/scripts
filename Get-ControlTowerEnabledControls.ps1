param(
    [Parameter(Mandatory=$true)]
    [string]$ControlArnFile
)

Write-Host "Reading control ARNs from: $ControlArnFile" -ForegroundColor Cyan

# Read in the list of control catalog ARNs
$controlArns = Get-Content -Path $ControlArnFile

# Pull down list of all controls once (both types)
$allControls = aws controltower list-controls --control-type PREVENTIVE | ConvertFrom-Json
$detectiveControls = aws controltower list-controls --control-type DETECTIVE | ConvertFrom-Json

$controlCatalog = @()
$controlCatalog += $allControls.controls
$controlCatalog += $detectiveControls.controls

Write-Host "Loaded $(($controlCatalog).Count) controls from Control Tower catalog." -ForegroundColor Green

# Function to list all enabled controls for all OUs
function Get-AllEnabledControls {
    # First list all OUs under your AWS Organization
    $orgOus = aws organizations list-organizational-units-for-parent `
        --parent-id $(aws organizations list-roots --query "Roots[0].Id" --output text) `
        | ConvertFrom-Json

    $enabled = @()

    foreach ($ou in $orgOus.OrganizationalUnits) {
        Write-Host "Checking enabled controls for OU: $($ou.Name) ($($ou.Id))..."

        $result = aws controltower list-enabled-controls `
            --target-identifier $ou.Id `
            --target-type ORGANIZATIONAL_UNIT | ConvertFrom-Json

        foreach ($ctrl in $result.enabledControls) {
            $enabled += [PSCustomObject]@{
                ControlIdentifier = $ctrl.controlIdentifier
                ControlArn        = $ctrl.Arn
                TargetOuName      = $ou.Name
                TargetOuId        = $ou.Id
            }
        }
    }

    return $enabled
}

# Get all enabled controls once
$enabledControls = Get-AllEnabledControls

Write-Host "`nSearching for matches..." -ForegroundColor Cyan

# Loop through each ARN provided by the user
foreach ($catalogArn in $controlArns) {

    Write-Host "`n=== Control Catalog ARN ===" -ForegroundColor Yellow
    Write-Host $catalogArn -ForegroundColor Gray

    # Map ARN → controlIdentifier
    $control = $controlCatalog | Where-Object { $_.Arn -eq $catalogArn }

    if (-not $control) {
        Write-Host "No match found in catalog!" -ForegroundColor Red
        continue
    }

    $identifier = $control.controlIdentifier
    Write-Host "Control Identifier: $identifier" -ForegroundColor Green

    # Find where this control is enabled
    $matches = $enabledControls | Where-Object {
        $_.ControlIdentifier -eq $identifier
    }

    if ($matches.Count -eq 0) {
        Write-Host "Control NOT enabled anywhere." -ForegroundColor DarkYellow
    }
    else {
        Write-Host "Enabled in the following OUs:" -ForegroundColor Cyan
        $matches | Format-Table TargetOuName, TargetOuId, ControlIdentifier -AutoSize
    }
}