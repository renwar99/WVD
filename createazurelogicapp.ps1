param(
	[Parameter(mandatory = $False)]
	[string]$TenantGroupName = "Default Tenant Group",

	[Parameter(mandatory = $True)]
	[string]$TenantName,

	[Parameter(mandatory = $True)]
	[string]$HostpoolName,

	[Parameter(mandatory = $True)]
	[string]$AutomationAccountName,

	[Parameter(mandatory = $True)]
	[string]$WebhookURI,

	[Parameter(mandatory = $True)]
	[int]$RecurrenceInterval,

	[Parameter(mandatory = $True)]
	[string]$AADTenantId,

	[Parameter(mandatory = $True)]
	[string]$SubscriptionId,

	[Parameter(mandatory = $True)]
	$BeginPeakTime,

	[Parameter(mandatory = $True)]
	$EndPeakTime,

	[Parameter(mandatory = $True)]
	$TimeDifference,

	[Parameter(mandatory = $True)]
	[int]$SessionThresholdPerCPU,

	[Parameter(mandatory = $True)]
	[int]$MinimumNumberOfRDSH,

	[Parameter(mandatory = $True)]
	[string]$MaintenanceTagName,

	[Parameter(mandatory = $True)]
	[int]$LimitSecondsToForceLogOffUser,

	[Parameter(mandatory = $False)]
	[string]$LogAnalyticsWorkspaceId,

	[Parameter(mandatory = $False)]
	[string]$LogAnalyticsPrimaryKey,

	[Parameter(mandatory = $True)]
	[string]$ConnectionAssetName,

	[Parameter(mandatory = $True)]
	[string]$Location,

	[Parameter(mandatory = $True)]
	[string]$ResourcegroupName,

	[Parameter(mandatory = $True)]
	[string]$LogOffMessageTitle,

	[Parameter(mandatory = $True)]
	[string]$LogOffMessageBody
)

#Initializing variables
$RDBrokerURL = "https://rdbroker.wvd.microsoft.com"
$ScriptRepoLocation = "https://raw.githubusercontent.com/Azure/RDS-Templates/master/wvd-templates/wvd-scaling-script"

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

[System.Collections.Generic.List[System.Object]]$HostpoolNames = $HostpoolName.Split(",")

# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force -Confirm:$false

# Import Az and AzureAD modules
Import-Module Az.LogicApp
Import-Module Az.Resources
Import-Module Az.Accounts

# Get the context
$Context = Get-AzContext
if ($Context -eq $null)
{
	Write-Error "Please authenticate to Azure using Login-AzAccount cmdlet and then run this script"
	exit
}


#Get the WVD context
$WVDContext = Get-RdsContext -DeploymentUrl $RDBrokerURL
if ($Context -eq $null)
{
	Write-Error "Please authenticate to WVD using Add-RDSAccount -DeploymentURL 'https://rdbroker.wvd.microsoft.com' cmdlet and then run this script"
	exit
}

# Select the subscription
$Subscription = Select-azSubscription -SubscriptionId $SubscriptionId
Set-AzContext -SubscriptionObject $Subscription.ExtendedProperties

# Get the Role Assignment of the authenticated user
$RoleAssignment = (Get-AzRoleAssignment -SignInName $Context.Account)

if ($RoleAssignment.RoleDefinitionName -eq "Owner" -or $RoleAssignment.RoleDefinitionName -eq "Contributor")
{

	# Check if the automation account exist in your Azure subscription
	$CheckRG = Get-AzResourceGroup -Name $ResourcegroupName -Location $Location -ErrorAction SilentlyContinue
	if (!$CheckRG) {
		Write-Output "The specified resourcegroup does not exist, creating the resourcegroup $ResourcegroupName"
		New-AzResourceGroup -Name $ResourcegroupName -Location $Location -Force
		Write-Output "ResourceGroup $ResourcegroupName created suceessfully"
	}

	#Creating Azure logic app to schedule job
	foreach ($HPName in $HostpoolNames) {

		# Check if the hostpool load balancer type is persistent.
		$HostPoolInfo = Get-RdsHostPool -TenantName $TenantName -Name $HPName

		if ($HostpoolInfo.LoadBalancerType -eq "Persistent") {
			Write-Output "$HPName hostpool configured with Persistent Load balancer.So scale script doesn't apply for this load balancertype.Scale script will execute only with these load balancer types BreadthFirst, DepthFirst. Please remove the from 'HostpoolName' input and try again"
			exit
		}

		$SessionHostsList = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HPName
		$SessionHostCount = ($SessionHostsList).Count


		#Check if the hostpool have session hosts and compare count with minimum number of rdsh value
		if ($SessionHostsList -eq $Null) {
			Write-Output "Hostpool '$HPName' doesn't have session hosts. Deployment Script will skip the basic scale script configuration for this hostpool."
			$RmHostpoolnames += $HPName
		}
		elseif ($SessionHostCount -le $MinimumNumberOfRDSH) {
			Write-Output "Hostpool '$HPName' has less than the minimum number of session host required."
			$Confirmation = Read-Host "Do you wish to continue configuring the scale script for these available session hosts? [y/n]"
			if ($Confirmation -eq 'n') {
				Write-Output "Configuring the scale script is skipped for this hostpool '$HPName'."
				$RmHostpoolnames += $HPName
			}
			else { Write-Output "Configuring the scale script for the hostpool : '$HPName' and will keep the minimum required session hosts in running mode." }
		}

		$RequestBody = @{
			"RDBrokerURL" = $RDBrokerURL;
			"AADTenantId" = $AADTenantId;
			"subscriptionid" = $subscriptionid;
			"TimeDifference" = $TimeDifference;
			"TenantGroupName" = $TenantGroupName;
			"TenantName" = $TenantName;
			"HostPoolName" = $HPName;
			"MaintenanceTagName" = $MaintenanceTagName;
			"LogAnalyticsWorkspaceId" = $LogAnalyticsWorkspaceId;
			"LogAnalyticsPrimaryKey" = $LogAnalyticsPrimaryKey;
			"ConnectionAssetName" = $ConnectionAssetName;
			"BeginPeakTime" = $BeginPeakTime;
			"EndPeakTime" = $EndPeakTime;
			"MinimumNumberOfRDSH" = $MinimumNumberOfRDSH;
			"SessionThresholdPerCPU" = $SessionThresholdPerCPU;
			"LimitSecondsToForceLogOffUser" = $LimitSecondsToForceLogOffUser;
			"LogOffMessageTitle" = $LogOffMessageTitle;
			"AutomationAccountName" = $AutomationAccountName;
			"LogOffMessageBody" = $LogOffMessageBody }
		$RequestBodyJson = $RequestBody | ConvertTo-Json
		$LogicAppName = ($HPName + "_" + "Autoscale" + "_" + "Scheduler").Replace(" ","")
		$SchedulerDeployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateUri "$ScriptRepoLocation/azureLogicAppCreation.json" -logicappname $LogicAppName -webhookURI $WebhookURI.Replace("`n","").Replace("`r","") -actionSettingsBody $RequestBodyJson -recurrenceInterval $RecurrenceInterval -Verbose
		if ($SchedulerDeployment.ProvisioningState -eq "Succeeded") {
			Write-Output "$HPName hostpool successfully configured with logic app scheduler"
		}
	}

}
else
{
	Write-Output "Authenticated user should have the Owner/Contributor permissions"
}
