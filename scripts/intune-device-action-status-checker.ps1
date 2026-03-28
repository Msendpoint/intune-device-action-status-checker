<#
.SYNOPSIS
    Retrieves remote device action results for an Intune-managed device using Microsoft Graph.

.DESCRIPTION
    This script connects to Microsoft Graph and looks up an Intune-managed device by its
    serial number. Once found, it queries the deviceActionResults endpoint to return all
    pending and historical remote actions (e.g., Wipe, Retire, Lock, Locate) along with
    their current state and timestamps.

    This is useful during incident response scenarios where you need to verify whether a
    previously issued remote action has been received and executed by the device, or is
    still sitting in a pending/queued state.

.PARAMETER SerialNumber
    The serial number of the target Intune-managed device.

.EXAMPLE
    .\Get-IntuneDeviceActionStatus.ps1 -SerialNumber "C02XG2JHJGH5"

    Finds the device with serial number C02XG2JHJGH5 and outputs all device action results
    in a formatted table.

.NOTES
    Author      : Senior PowerShell / M365 Automation Engineer
    Version     : 1.0.0
    Requires    : Microsoft.Graph PowerShell SDK
                  DeviceManagementManagedDevices.Read.All (Graph permission)
    Install SDK : Install-Module Microsoft.Graph -Scope CurrentUser

.LINK
    https://learn.microsoft.com/en-us/graph/api/manageddevice-list-deviceactionresults
#>

[CmdletBinding()]
param (
    [Parameter(
        Mandatory = $true,
        HelpMessage = "The serial number of the Intune-managed device to query."
    )]
    [ValidateNotNullOrEmpty()]
    [string]$SerialNumber
)

#region --- Prerequisites Check ---

# Ensure the Microsoft.Graph module is available
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
    Write-Error "Microsoft.Graph module is not installed. Run: Install-Module Microsoft.Graph -Scope CurrentUser"
    exit 1
}

#endregion

#region --- Authentication ---

Write-Verbose "Connecting to Microsoft Graph with required scopes..."
try {
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -ErrorAction Stop
    Write-Verbose "Successfully connected to Microsoft Graph."
} catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    exit 1
}

#endregion

#region --- Device Lookup ---

Write-Verbose "Searching for Intune-managed device with serial number: $SerialNumber"

try {
    $device = Get-MgDeviceManagementManagedDevice `
        -Filter "serialNumber eq '$SerialNumber'" `
        -Select "id,deviceName,managedDeviceOwnerType,operatingSystem,complianceState" `
        -ErrorAction Stop
} catch {
    Write-Error "Error querying Intune managed devices: $_"
    exit 1
}

if (-not $device) {
    Write-Warning "No Intune-managed device found with serial number: $SerialNumber"
    exit 0
}

# Handle edge case where multiple devices match (unlikely but possible in shared environments)
if ($device -is [array]) {
    Write-Warning "Multiple devices found with serial number '$SerialNumber'. Using the first result."
    $device = $device[0]
}

$deviceId = $device.Id
Write-Host "Device found:" -ForegroundColor Green
Write-Host "  Name            : $($device.DeviceName)"
Write-Host "  ID              : $deviceId"
Write-Host "  OS              : $($device.OperatingSystem)"
Write-Host "  Owner Type      : $($device.ManagedDeviceOwnerType)"
Write-Host "  Compliance State: $($device.ComplianceState)"
Write-Host ""

#endregion

#region --- Device Action Results ---

Write-Verbose "Retrieving device action results for device ID: $deviceId"

try {
    $actionResultsResponse = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$deviceId/deviceActionResults" `
        -ErrorAction Stop
} catch {
    Write-Error "Failed to retrieve device action results: $_"
    exit 1
}

$actionResults = $actionResultsResponse.value

if (-not $actionResults -or $actionResults.Count -eq 0) {
    Write-Host "No remote device actions found for this device." -ForegroundColor Yellow
    exit 0
}

#endregion

#region --- Output Results ---

Write-Host "Remote Device Action Results for: $($device.DeviceName)" -ForegroundColor Cyan
Write-Host "Total actions found: $($actionResults.Count)" -ForegroundColor Cyan
Write-Host ""

$formattedResults = $actionResults | ForEach-Object {
    [PSCustomObject]@{
        Action      = $_.actionName
        State       = $_.actionState
        StartTime   = if ($_.startDateTime) { [datetime]$_.startDateTime } else { 'N/A' }
        LastUpdated = if ($_.lastUpdatedDateTime) { [datetime]$_.lastUpdatedDateTime } else { 'N/A' }
    }
}

$formattedResults | Sort-Object StartTime -Descending | Format-Table -AutoSize

# Highlight any actions still in a pending or active state
$pendingActions = $formattedResults | Where-Object { $_.State -in @('pending', 'sent', 'active') }
if ($pendingActions) {
    Write-Host "WARNING: The following actions are still pending/in-progress:" -ForegroundColor Yellow
    $pendingActions | Format-Table -AutoSize
}

#endregion

#region --- Disconnect ---

Write-Verbose "Disconnecting from Microsoft Graph."
Disconnect-MgGraph | Out-Null

#endregion
