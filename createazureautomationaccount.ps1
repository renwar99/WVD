param(
	[Parameter(mandatory = $True)][string]$Sub,
	[Parameter(mandatory = $true)][string]$ResourceGroupName,
	[Parameter(mandatory = $True)][string]$AutomationAccountNameM,
	[Parameter(mandatory = $True)][string]$Location,
    [Parameter(mandatory = $True)][string]$RunbookName,
    [Parameter(mandatory = $True)][string]$WebhookName,
    [Parameter(mandatory = $True)][string]$ScriptRepoLocation
)


Write-Output "Subscription: $($Sub)"
Write-Output "ResourceGroupName: $($ResourceGroupName)"
Write-Output "AutomationAccountName: $($AutomationAccountNameM)"
Write-Output "Location: $($Location)"
Write-Output "RunbookName: $($RunbookName)"
Write-Output "WebhookName: $($WebhookName)"
Write-Output "ScriptRepoLocation: $($ScriptRepoLocation)"

$WorkspaceName=$null

# Get the azure context
$Context = Get-AzContext
if ($Context -eq $null)
{
	Write-Error "Please authenticate to Azure using Login-AzAccount cmdlet and then run this script"
	exit
}

# Select the subscription

Set-AzContext -SubscriptionObject $(Select-azSubscription -SubscriptionId $Sub).ExtendedProperties

# Get the Role Assignment of the authenticated user
$RoleAssignment = (Get-AzRoleAssignment -SignInName $Context.Account)

if ($RoleAssignment.RoleDefinitionName -eq "Owner" -or $RoleAssignment.RoleDefinitionName -eq "Contributor")
{

	#Check if the resourcegroup exist
	$ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction SilentlyContinue
	if ($ResourceGroup -eq $null) {
		New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force -Verbose
		Write-Output "Resource Group was created with name $ResourceGroupName"
	}

	#Check if the Automation Account exist
	$AutomationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountNameM -ErrorAction SilentlyContinue
	if ($AutomationAccount -eq $null) {
		New-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountNameM -Location $Location -Plan Free -Verbose
		Write-Output "Automation Account was created with name $AutomationAccountNameM"
	}

	$RequiredModules = @(
		[pscustomobject]@{ ModuleName = 'Az.Accounts'; ModuleVersion = '1.6.4' }
		[pscustomobject]@{ ModuleName = 'Microsoft.RDInfra.RDPowershell'; ModuleVersion = '1.0.1288.1' }
		[pscustomobject]@{ ModuleName = 'OMSIngestionAPI'; ModuleVersion = '1.6.0' }
		[pscustomobject]@{ ModuleName = 'Az.Compute'; ModuleVersion = '3.1.0' }
		[pscustomobject]@{ ModuleName = 'Az.Resources'; ModuleVersion = '1.8.0' }
		[pscustomobject]@{ ModuleName = 'Az.Automation'; ModuleVersion = '1.3.4' }
	)

	#Function to add required modules to Azure Automation account
	function AddingModules-toAutomationAccount {
		param(
			[Parameter(mandatory = $true)]
			[string]$ResourceGroupName,

			[Parameter(mandatory = $true)]
			[string]$AutomationAccountName,

			[Parameter(mandatory = $true)]
			[string]$ModuleName,

			# if not specified latest version will be imported
			[Parameter(mandatory = $false)]
			[string]$ModuleVersion
		)

        Write-Output "ResourceGroupName: $($ResourceGroupName)"
        Write-Output "AutomationAccountName: $($AutomationAccountName)"
        Write-Output "ModuleName: $($ModuleName)"
        Write-Output "ModuleVersion: $($ModuleVersion)"

		$Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName $ModuleVersion%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"
        Write-Output "Url: $($Url)"
		[array]$SearchResult = Invoke-RestMethod -Method Get -Uri $Url
		if ($SearchResult.Count -ne 1) {
			$SearchResult = $SearchResult[0]
		}

		if (!$SearchResult) {
			Write-Error "Could not find module '$ModuleName' on PowerShell Gallery."
		}
		elseif ($SearchResult.Count -and $SearchResult.Length -gt 1) {
			Write-Error "Module name '$ModuleName' returned multiple results. Please specify an exact module name."
		}
		else {
			$PackageDetails = Invoke-RestMethod -Method Get -Uri $SearchResult.Id

			if (!$ModuleVersion) {
				$ModuleVersion = $PackageDetails.entry.properties.version
			}

			$ModuleContentUrl = "https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion"
             Write-Output "ModuleContentUrl: $($ModuleContentUrl)"
			# Test if the module/version combination exists
			try {
				Invoke-RestMethod $ModuleContentUrl -ErrorAction Stop | Out-Null
				$Stop = $False
			}
			catch {
				Write-Error "Module with name '$ModuleName' of version '$ModuleVersion' does not exist. Are you sure the version specified is correct?"
				$Stop = $True
			}

			if (!$Stop) {

				# Find the actual blob storage location of the module
				do {
					$ActualUrl = $ModuleContentUrl
					$ModuleContentUrl = $(Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore).Headers.Location
				} while ($ModuleContentUrl -ne $Null)

				New-AzAutomationModule `
 					-ResourceGroupName $ResourceGroupName `
 					-AutomationAccountName $AutomationAccountName `
 					-Name $ModuleName `
 					-ContentLink $ActualUrl
			}
		}
	}

	#Function to check if the module is imported
	function Check-IfModuleIsImported {
		param(
			[Parameter(mandatory = $true)]
			[string]$ResourceGroupName,

			[Parameter(mandatory = $true)]
			[string]$AutomationAccountName,

			[Parameter(mandatory = $true)]
			[string]$ModuleName
		)

		$IsModuleImported = $false
		while (!$IsModuleImported) {
			$IsModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ModuleName -ErrorAction SilentlyContinue
			if ($IsModule.ProvisioningState -eq "Succeeded") {
				$IsModuleImported = $true
				Write-Output "Successfully $ModuleName module imported into Automation Account Modules..."
			}
			else {
				Write-Output "Waiting for to import module $ModuleName into Automation Account Modules ..."
			}
		}
	}

	#$Runbook = Get-AzAutomationRunbook -Name $RunbookName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
	#if($Runbook -eq $null){
	#Creating a runbook and published the basic Scale script file
    $TempParameter= @{
        "_artifactsLocation" = "$($ScriptRepoLocation)wvd-scaling-script/"
        "_artifactsLocationSasToken" = ""
        "existingAutomationAccountName" = $AutomationAccountName
        "RunbookName" = $RunbookName
    }
    Write-Output "ScriptRepoLocation: $($ScriptRepoLocation)wvd-scaling-script/runbookCreationTemplate.json"
	$DeploymentStatus = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateUri "$($ScriptRepoLocation)wvd-scaling-script/runbookCreationTemplate.json" -TemplateParameterObject $TempParameter
	if ($DeploymentStatus.ProvisioningState -eq "Succeeded") {

		#Check if the Webhook URI exists in automation variable
		$WebhookURI = Get-AzAutomationVariable -Name "WebhookURI" -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
		if (!$WebhookURI) {
			$Webhook = New-AzAutomationWebhook -Name $WebhookName -RunbookName $runbookName -IsEnabled $True -ExpiryTime (Get-Date).AddYears(5) -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Force
			Write-Output "Automation Account Webhook is created with name '$WebhookName'"
			$URIofWebhook = $Webhook.WebhookURI | Out-String
			New-AzAutomationVariable -Name "WebhookURI" -Encrypted $false -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Value $URIofWebhook
			Write-Output "Webhook URI stored in Azure Automation Acccount variables"
			$WebhookURI = Get-AzAutomationVariable -Name "WebhookURI" -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
		}
	}
	#}
	# Required modules imported from Automation Account Modules gallery for Scale Script execution
	foreach ($Module in $RequiredModules) {
		# Check if the required modules are imported 
		$ImportedModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountNameM -Name $Module.ModuleName -ErrorAction SilentlyContinue
		if ($ImportedModule -eq $Null) {
			AddingModules-toAutomationAccount -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountNameM -ModuleName $Module.ModuleName
			Check-IfModuleIsImported -ModuleName $Module.ModuleName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName 
		}
		elseif ($ImportedModule.version -ne $Module.ModuleVersion) {
			AddingModules-toAutomationAccount -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountNameM -ModuleName $Module.ModuleName
			Check-IfModuleIsImported -ModuleName $Module.ModuleName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountNameM 
		}
	}
	if ($WorkspaceName -ne $null) {
		#Check if the log analytic workspace is exist
		$LAWorkspace = Get-AzOperationalInsightsWorkspace | Where-Object { $_.Name -eq $WorkspaceName }
		if (!$LAWorkspace) {
			Write-Error "Provided log analytic workspace doesn't exist in your Subscription."
			exit
		}
		$WorkSpace = Get-AzOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $LAWorkspace.ResourceGroupName -Name $WorkspaceName -WarningAction Ignore
		$LogAnalyticsPrimaryKey = $Workspace.PrimarySharedKey
		$LogAnalyticsWorkspaceId = (Get-AzOperationalInsightsWorkspace -ResourceGroupName $LAWorkspace.ResourceGroupName -Name $workspaceName).CustomerId.GUID

		# Create the function to create the authorization signature
		function Build-Signature ($customerId,$sharedKey,$date,$contentLength,$method,$contentType,$resource)
		{
			$xHeaders = "x-ms-date:" + $date
			$stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

			$bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
			$keyBytes = [Convert]::FromBase64String($sharedKey)

			$sha256 = New-Object System.Security.Cryptography.HMACSHA256
			$sha256.Key = $keyBytes
			$calculatedHash = $sha256.ComputeHash($bytesToHash)
			$encodedHash = [Convert]::ToBase64String($calculatedHash)
			$authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
			return $authorization
		}

		# Create the function to create and post the request
		function Post-LogAnalyticsData ($customerId,$sharedKey,$body,$logType)
		{
			$method = "POST"
			$contentType = "application/json"
			$resource = "/api/logs"
			$rfc1123date = [datetime]::UtcNow.ToString("r")
			$contentLength = $body.Length
			$signature = Build-Signature `
 				-customerId $customerId `
 				-sharedKey $sharedKey `
 				-Date $rfc1123date `
 				-contentLength $contentLength `
 				-FileName $fileName `
 				-Method $method `
 				-ContentType $contentType `
 				-resource $resource
			$uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

			$headers = @{
				"Authorization" = $signature;
				"Log-Type" = $logType;
				"x-ms-date" = $rfc1123date;
				"time-generated-field" = $TimeStampField;
			}

			$response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
			return $response.StatusCode

		}

		# Specify the name of the record type that you'll be creating
		$TenantScaleLogType = "WVDTenantScale_CL"

		# Specify a field with the created time for the records
		$TimeStampField = Get-Date
		$TimeStampField = $TimeStampField.GetDateTimeFormats(115)


		# Submit the data to the API endpoint

		#Custom WVDTenantScale Table
		$CustomLogWVDTenantScale = @"
[
    {
    "hostpoolName":" ",
    "logmessage": " "
    }
]
"@

		Post-LogAnalyticsData -customerId $LogAnalyticsWorkspaceId -sharedKey $LogAnalyticsPrimaryKey -Body ([System.Text.Encoding]::UTF8.GetBytes($CustomLogWVDTenantScale)) -logType $TenantScaleLogType


		Write-Output "Log Analytics workspace id:$LogAnalyticsWorkspaceId"
		Write-Output "Log Analytics workspace primarykey:$LogAnalyticsPrimaryKey"
		Write-Output "Automation Account Name:$AutomationAccountName"
		Write-Output "Webhook URI: $($WebhookURI.value)"
        return $LogAnalyticsWorkspaceId,$LogAnalyticsPrimaryKey,$AutomationAccountName,$($WebhookURI.value)
	} else {
		Write-Output "Automation Account Name:$AutomationAccountName"
		Write-Output "Webhook URI: $($WebhookURI.value)"
        return $AutomationAccountName,$($WebhookURI.value)
	}
}
else
{
	Write-Output "Authenticated user should have the Owner/Contributor permissions"
}
