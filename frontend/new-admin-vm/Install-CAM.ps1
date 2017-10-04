# Install-CAM.ps1
# Compile to a local .zip file via this command:
# Publish-AzureVMDscConfiguration -ConfigurationPath .\Install-CAM.ps1 -ConfigurationArchivePath .\Install-CAM.ps1.zip
# And then push to GitHUB.
#
# Or to push to Azure Storage:
#
# example:
#
# $StorageAccount = 'teradeploy'
# $StorageKey = '<put key here>'
# $StorageContainer = 'binaries'
# 
# $StorageContext = New-AzureStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $StorageKey
# Publish-AzureVMDscConfiguration -ConfigurationPath .\Install-CAM.ps1  -ContainerName $StorageContainer -StorageContext $StorageContext
#
#
Configuration InstallCAM
{
	# One day pull from Oracle as per here? https://github.com/gregjhogan/cJre8/blob/master/DSCResources/cJre8/cJre8.schema.psm1
    param
    (
        [string]
        $LocalDLPath = "$env:systemdrive\WindowsAzure\PCoIPCAMInstall",

        [Parameter(Mandatory)]
		[String]$sourceURI,

        [Parameter(Mandatory)]
		[String]$templateURI,

        [Parameter(Mandatory)]
		[String]$templateAgentURI,

        [Parameter(Mandatory)]
		[System.Management.Automation.PSCredential]$registrationCodeAsCred,

        [Parameter(Mandatory)]
		[System.Management.Automation.PSCredential]$CAMDeploymentInfo,

        [string]
        $javaInstaller = "jdk-8u91-windows-x64.exe",

        [string]
        $tomcatInstaller = "apache-tomcat-8.0.39-windows-x64.zip",

        [string]
        $brokerWAR = "pcoip-broker.war",

        [string]
        $adminWAR = "CloudAccessManager.war",

        [string]
        $agentARM = "server2016-standard-agent.json",

        [string]
        $gaAgentARM = "server2016-graphics-agent.json",

        [string]
        $linuxAgentARM = "rhel-standard-agent.json",

        [Parameter(Mandatory)]
        [String]$domainFQDN,

        [Parameter(Mandatory)]
		[String]$adminDesktopVMName,

        [Parameter(Mandatory)]
        [String]$domainGroupAppServersJoin,

        [Parameter(Mandatory)]
        [String]$existingVNETName,

        [Parameter(Mandatory)]
        [String]$existingSubnetName,

        [Parameter(Mandatory)]
        [String]$storageAccountName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$VMAdminCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainAdminCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AzureCreds,

        [Parameter(Mandatory=$false)]
		[String]$tenantID,

        [Parameter(Mandatory)]
        [String]$DCVMName, #without the domain suffix

        [Parameter(Mandatory)]
        [String]$RGName, #Azure resource group name

        [Parameter(Mandatory)]
        [String]$gitLocation,

        [Parameter(Mandatory)]
        [String]$sumoCollectorID,

		[Parameter(Mandatory=$false)]
        [String]$brokerPort = "8444",

		#For application gateway
		[Parameter(Mandatory=$true)]
		[string]$AGsubnetRef,

		[Parameter(Mandatory=$true)]
		[string]$AGbackendIpAddressDefault,

		[Parameter(Mandatory=$true)]
		[string]$AGbackendIpAddressForPathRule1,

		[Parameter(Mandatory=$true)] #passed as credential to prevent logging of any embedded access keys
		[System.Management.Automation.PSCredential]$AGtemplateUri,

		[Parameter(Mandatory=$true)]
		[string]$camSaasUri,

		[Parameter(Mandatory=$false)]
		[bool]$verifyCAMSaaSCertificate=$true,

		[Parameter(Mandatory=$true)]
		[string]$keyVaultId
	)

	$standardVMSize = "Standard_D2_v2"
	$graphicsVMSize = "Standard_NV6"

	$dcvmfqdn = "$DCVMName.$domainFQDN"
	$pbvmfqdn = "$env:computername.$domainFQDN"
	$family   = "Windows Server 2016"

	#Java locations
	$JavaRootLocation = "$env:systemdrive\Program Files\Java\jdk1.8.0_91"
	$JavaBinLocation = $JavaRootLocation + "\bin"
	$JavaLibLocation = $JavaRootLocation + "\jre\lib"

	#Tomcat locations
	$localtomcatpath = "$env:systemdrive\tomcat"
	$CatalinaHomeLocation = "$localtomcatpath\apache-tomcat-8.0.39"
	$CatalinaBinLocation = $CatalinaHomeLocation + "\bin"

	$brokerServiceName = "CAMBroker"
	$AUIServiceName = "CAMAUI"

	# Retry for CAM Registration
	$retryCount = 3
	$delay = 10

	Import-DscResource -ModuleName xPSDesiredStateConfiguration

    Node "localhost"
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

		xRemoteFile Download_Java_Installer
		{
			Uri = "$sourceURI/$javaInstaller"
			DestinationPath = "$LocalDLPath\$javaInstaller"
			MatchSource = $false
		}

		xRemoteFile Download_Tomcat_Installer
		{
			Uri = "$sourceURI/$tomcatInstaller"
			DestinationPath = "$LocalDLPath\$tomcatInstaller"
			MatchSource = $false
		}

		xRemoteFile Download_Keystore
		{
			Uri = "$sourceURI/.keystore"
			DestinationPath = "$LocalDLPath\.keystore"
			MatchSource = $false
		}

		xRemoteFile Download_Broker_WAR
		{
			Uri = "$sourceURI/$brokerWAR"
			DestinationPath = "$LocalDLPath\$brokerWAR"
			MatchSource = $false
		}

		xRemoteFile Download_Admin_WAR
		{
			Uri = "$sourceURI/$adminWAR"
			DestinationPath = "$LocalDLPath\$adminWAR"
			MatchSource = $false
		}

		xRemoteFile Download_Agent_ARM
		{
			Uri = "$templateAgentURI/$agentARM"
			DestinationPath = "$LocalDLPath\$agentARM"
			MatchSource = $false
		}

		xRemoteFile Download_Ga_Agent_ARM
		{
			Uri = "$templateAgentURI/$gaAgentARM"
			DestinationPath = "$LocalDLPath\$gaAgentARM"
			MatchSource = $false
		}

		xRemoteFile Download_Linux_Agent_ARM
		{
			Uri = "$templateAgentURI/$linuxAgentARM"
			DestinationPath = "$LocalDLPath\$linuxAgentARM"
			MatchSource = $false
		}

        File Sumo_Directory 
        {
            Ensure          = "Present"
            Type            = "Directory"
            DestinationPath = "C:\sumo"
        }

        # Aim to install the collector first and start the log collection before any 
        # other applications are installed.
        Script Install_SumoCollector
        {
            DependsOn  = "[File]Sumo_Directory"
            GetScript  = { @{ Result = "Install_SumoCollector" } }

            TestScript = { 
                return Test-Path "C:\sumo\sumo.conf" -PathType leaf
                }

            SetScript  = {
                Write-Verbose "Install_SumoCollector"

                $installerFileName = "SumoCollector_windows-x64_19_182-25.exe"
                $sumo_package = "$using:sourceURI/$installerFileName"
                $sumo_config = "$using:gitLocation/sumo.conf"
                $sumo_collector_json = "$using:gitLocation/sumo-admin-vm.json"
                $dest = "C:\sumo"
                Invoke-WebRequest -UseBasicParsing -Uri $sumo_config -PassThru -OutFile "$dest\sumo.conf"
                Invoke-WebRequest -UseBasicParsing -Uri $sumo_collector_json -PassThru -OutFile "$dest\sumo-admin-vm.json"
                #
                #Insert unique ID
                $collectorID = "$using:sumoCollectorID"
                (Get-Content -Path "$dest\sumo.conf").Replace("collectorID", $collectorID) | Set-Content -Path "$dest\sumo.conf"
                
                Invoke-WebRequest $sumo_package -OutFile "$dest\$installerFileName"
                
                #install the collector
                $command = "$dest\$installerFileName -console -q"
                Invoke-Expression $command

				# Wait for collector to be installed before exiting this configuration.
				#### Note if we change binary versions we will need to change registry path - 7857-4527-9352-4688 will change ####
				$retrycount = 1800
				while ($retryCount -gt 0)
				{
					$readyToConfigure = ( Get-Item "Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7857-4527-9352-4688"  -ErrorAction SilentlyContinue )

					if ($readyToConfigure)
					{
						break   #success
					}
					else
					{
						Start-Sleep -s 1;
						$retrycount = $retrycount - 1;
						if ( $retrycount -eq 0)
						{
							throw "Sumo collector not installed in time."
						}
						else
						{
							Write-Host "Waiting for Sumo collector to be installed"
						}
					}
				}
            }
        }
        #
		# One day can split this to 'install java' and 'configure java environemnt' and use 'package' dsc like here:
		# http://stackoverflow.com/questions/31562451/installing-jre-using-powershell-dsc-hangs
        Script Install_Java
        {
            DependsOn  = "[xRemoteFile]Download_Java_Installer"
            GetScript  = { @{ Result = "Install_Java" } }

            #TODO: Just check for a directory being present? What to do when Java version changes? (Can also check registry key as in SetScript.)
            TestScript = {
                return Test-Path "$using:JavaBinLocation"
			}
            SetScript  = {
                Write-Verbose "Install_Java"

				# Run the installer. Start-Process does not work due to permissions issue however '&' calling will not wait so looks for registry key as 'completion.'
				# Start-Process $LocalDLPath\$javaInstaller -ArgumentList '/s ADDLOCAL="ToolsFeature,SourceFeature,PublicjreFeature"' -Wait
				& "$using:LocalDLPath\$using:javaInstaller" /s ADDLOCAL="ToolsFeature,SourceFeature,PublicjreFeature"

				$retrycount = 1800
				while ($retryCount -gt 0)
				{
					$readyToConfigure = ( Get-Item "Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{26A24AE4-039D-4CA4-87B4-2F86418091F0}"  -ErrorAction SilentlyContinue )
					# don't wait for {64A3A4F4-B792-11D6-A78A-00B0D0180910} - that's the JDK. The JRE is installed 2nd {26A...} so wait for that.

					if ($readyToConfigure)
					{
						break   #success
					}
					else
					{
    					Start-Sleep -s 1;
						$retrycount = $retrycount - 1;
						if ( $retrycount -eq 0)
						{
							throw "Java not installed in time."
						}
						else
						{
							Write-Host "Waiting for Java to be installed"
						}
					}
				}

				Write-Host "Setting up Java paths and environment"

				#set path. Don't add strings that are already there...

				$NewPath = $env:Path
				if ($NewPath -notlike "*"+$using:JavaBinLocation+"*")
				{
    				#put java path in front of the Oracle defined path
				    $NewPath= $using:JavaBinLocation + ";" + $NewPath
				}

				[System.Environment]::SetEnvironmentVariable("Path", $NewPath, "Machine")
				[System.Environment]::SetEnvironmentVariable("JAVA_HOME", $using:JavaRootLocation, "Machine")
				[System.Environment]::SetEnvironmentVariable("classpath", $using:JavaLibLocation, "Machine")
				$env:Path = $NewPath
				$env:JAVA_HOME = $using:JavaRootLocation
				$env:classpath = $using:JavaLibLocation


				Write-Host "Waiting for JVM.dll"
				$JREHome = $using:JavaRootLocation + "\jre"
				$JVMServerdll = $JREHome + "\bin\server\jvm.dll"

				$retrycount = 1800
				while ($retryCount -gt 0)
				{
					$readyToConfigure = ( Get-Item $JVMServerdll -ErrorAction SilentlyContinue )
					# don't wait for {64A3A4F4-B792-11D6-A78A-00B0D0180910} - that's the JDK. The JRE is installed 2nd {26A...} so wait for that.

					if ($readyToConfigure)
					{
						break   #success
					}
					else
					{
    					Start-Sleep -s 1;
						$retrycount = $retrycount - 1;
						if ( $retrycount -eq 0)
						{
							throw "JVM.dll not installed in time."
						}
						else
						{
							Write-Host "Waiting for JVM.dll to be installed"
						}
					}
				}

				# Reboot machine - seems to need to happen to get Tomcat to install??? Perhaps not after environment fixes. Needs testing.
				$global:DSCMachineStatus = 1
            }
        }

		Script Install_Tomcat
        {
            DependsOn = @("[xRemoteFile]Download_Tomcat_Installer", "[Script]Install_Java", "[xRemoteFile]Download_Keystore")
            GetScript  = { @{ Result = "Install_Tomcat" } }

            TestScript = { 
				if ( $env:CATALINA_HOME )
                {
					return $true
				}
				else
				{
					return $false
				}
			}
            SetScript  = {
                Write-Verbose "Install_Tomcat"

				#just going 'manual' now since installer has been a massive PITA
                #(but perhaps unfairly so since it might have been affected by some Java install issues I had previously as well.)

		        $LocalDLPath = $using:LocalDLPath
		        $tomcatInstaller = $using:tomcatInstaller
				$localtomcatpath = $using:localtomcatpath
				$CatalinaHomeLocation = $using:CatalinaHomeLocation
				$CatalinaBinLocation = $using:CatalinaBinLocation

				#make sure we get a clean install
				Remove-Item $localtomcatpath -Force -Recurse -ErrorAction SilentlyContinue

				Expand-Archive "$LocalDLPath\$tomcatInstaller" -DestinationPath $localtomcatpath


				Write-Host "Setting Paths and Tomcat environment"

				$NewPath = $env:Path
				if ($NewPath -notlike "*"+$CatalinaBinLocation+"*")
				{
				    #put tomcat path at the end
				    $NewPath= $NewPath + ";" + $CatalinaBinLocation
				}

				[System.Environment]::SetEnvironmentVariable("Path", $NewPath, "Machine")
				[System.Environment]::SetEnvironmentVariable("CATALINA_HOME", $CatalinaHomeLocation, "Machine")
				$env:Path = $NewPath
				$env:CATALINA_HOME = $CatalinaHomeLocation
	        }
        }

		Script Setup_AUI_Service
        {
            DependsOn = @("[Script]Install_Tomcat", "[xRemoteFile]Download_Keystore")
            GetScript  = { @{ Result = "Setup_AUI_Service" } }

            TestScript = {
				return !!(Get-Service $using:AUIServiceName -ErrorAction SilentlyContinue)
			}

			SetScript = {

				Write-Host "Configuring Tomcat for $using:AUIServiceName service"

				$catalinaHome = $using:CatalinaHomeLocation
				$catalinaBase = "$catalinaHome" #\$using:AUIServiceName" <---- don't change this without changing log collector location currently in sumo-admin-vm.json

				$env:CATALINA_BASE = $catalinaBase

				# make new instance location - copying the directories specified
				# here: https://tomcat.apache.org/tomcat-8.0-doc/windows-service-howto.html

				# clear out any old cruft first
#				Remove-Item "$catalinaBase" -Force -Recurse -ErrorAction SilentlyContinue
#				Copy-Item "$catalinaHome\conf" "$catalinaBase\conf" -Recurse -ErrorAction SilentlyContinue
#				Copy-Item "$catalinaHome\logs" "$catalinaBase\logs" -Recurse -ErrorAction SilentlyContinue
#				Copy-Item "$catalinaHome\temp" "$catalinaBase\temp" -Recurse -ErrorAction SilentlyContinue
#				Copy-Item "$catalinaHome\webapps" "$catalinaBase\webapps" -Recurse -ErrorAction SilentlyContinue
#				Copy-Item "$catalinaHome\work" "$catalinaBase\work" -Recurse -ErrorAction SilentlyContinue

				$serverXMLFile = $catalinaBase + '\conf\server.xml'
				$origServerXMLFile = $catalinaBase + '\conf\server.xml.orig'

				# back up server.xml file if not done in a previous round
				if( -not ( Get-Item ($origServerXMLFile) -ErrorAction SilentlyContinue ) )
				{
					Copy-Item -Path ($serverXMLFile) `
						-Destination ($origServerXMLFile)
				}

				#update server.xml file
				$xml = [xml](Get-Content ($origServerXMLFile))

				# port 8080 unencrypted connector - is there by default
				#$unencConnector = [xml] ('<Connector port="8080" protocol="HTTP/1.1" connectionTimeout="20000" redirectPort="8443" />')

				#$xml.Server.Service.InsertBefore(
					# new child
				#	$xml.ImportNode($unencConnector.Connector,$true),
					#ref child
			    #	$xml.Server.Service.Engine )

				$NewConnector = [xml] ('<Connector
					port="8443"
					protocol="org.apache.coyote.http11.Http11NioProtocol"
					SSLEnabled="true"
					keystoreFile="'+$using:LocalDLPath+'\.keystore"
					maxThreads="2000" scheme="https" secure="true"
					clientAuth="false" sslProtocol="TLS"
					SSLEngine="on" keystorePass="changeit"
					SSLPassword="changeit"
					sslEnabledProtocols="TLSv1.0,TLSv1.1,TLSv1.2"
					ciphers="TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,TLS_RSA_WITH_AES_128_CBC_SHA"
					/>')

				# port 8443 encrypted connector 

				$xml.Server.Service.InsertBefore(
					# new child
					$xml.ImportNode($NewConnector.Connector,$true),
					#ref child
					$xml.Server.Service.Engine )

				$xml.save($ServerXMLFile)



				Write-Host "Opening port 8443 and 8080"

				#open port in firewall
				netsh advfirewall firewall add rule name="Tomcat Port 8443" dir=in action=allow protocol=TCP localport=8443
				netsh advfirewall firewall add rule name="Tomcat Port 8080" dir=in action=allow protocol=TCP localport=8080


				# Install and set service to start automatically

				& "$using:CatalinaBinLocation\service.bat" install $using:AUIServiceName
				Write-Host "Tomcat Installer exit code: $LASTEXITCODE"
				Start-Sleep -s 10  #TODO: Is this sleep ACTUALLY needed?

				Write-Host "Starting Tomcat Service for $using:AUIServiceName"
				Set-Service $using:AUIServiceName -startuptype "automatic"
	        }
        }

        Script Install_AUI
        {
            DependsOn  = @("[xRemoteFile]Download_Admin_WAR",
						   "[xRemoteFile]Download_Agent_ARM",
						   "[Script]Setup_AUI_Service",
						   "[xRemoteFile]Download_Ga_Agent_ARM",
						   "[xRemoteFile]Download_Linux_Agent_ARM")

            GetScript  = { @{ Result = "Install_AUI" } }

            TestScript = {
				$CatalinaHomeLocation = $using:CatalinaHomeLocation
				$catalinaBase = "$CatalinaHomeLocation" # \$using:AUIServiceName"
				$WARPath = "$catalinaBase\webapps\$using:adminWAR"

                return Test-Path $WARPath -PathType Leaf
			}

            SetScript  = {
		        $LocalDLPath = $using:LocalDLPath
				$adminWAR = $using:adminWAR
                $agentARM = $using:agentARM
                $gaAgentARM = $using:gaAgentARM
				$linuxAgentARM = $using:linuxAgentARM
				$localtomcatpath = $using:localtomcatpath
				$CatalinaHomeLocation = $using:CatalinaHomeLocation
				$catalinaBase = "$CatalinaHomeLocation" #\$using:AUIServiceName"

                Write-Verbose "Ensure Nuget Package Provider and AzureRM module are installed"

				If(-not [bool](Get-PackageProvider -ListAvailable | where {$_.Name -eq "NuGet"}))
				{
	                Write-Verbose "Installing NuGet"
					Install-packageProvider -Name NuGet -Force
				}

				If(-not [bool](Get-InstalledModule | where {$_.Name -eq "AzureRM"}))
				{
	                Write-Verbose "Installing AzureRM"
					Install-Module -Name AzureRM -Force
				}
				

                Write-Verbose "Install_CAM"

				copy "$LocalDLPath\$adminWAR" ($catalinaBase + "\webapps")

				$svc = get-service $using:AUIServiceName
				if ($svc.Status -ne "Stopped") {$svc.stop()}

				Write-Host "Re-generating CAM configuration file."

				#Now create the new output file.
				#TODO - really only a couple parameters are used and set properly now. Needs cleanup.
				$domainsplit = $using:domainFQDN
				$domainsplit = $domainsplit.split(".".2)
				$domainleaf = $domainsplit[0]  # get the first part of the domain name (before .local or .???)
				$domainroot = $domainsplit[1]  # get the second part of the domain name
				$date = Get-Date
				$domainControllerFQDN = $using:dcvmfqdn
				$RGNameLocal        = $using:RGName

				$auProperties = @"
#$date
cn=Users
dom=$domainleaf
dcDomain = $domainleaf
dc=$domainroot
adServerHostAddress=$domainControllerFQDN
resourceGroupName=$RGNameLocal
CAMSessionTimeoutMinutes=480
domainGroupAppServersJoin="$using:domainGroupAppServersJoin"
"@

				$targetDir = "$CatalinaHomeLocation\adminproperty"
				$configFileName = "$targetDir\config.properties"

				if(-not (Test-Path $targetDir))
				{
					New-Item $targetDir -type directory
				}

				if(-not (Test-Path $configFileName))
				{
					New-Item $configFileName -type file
				}

				Set-Content $configFileName $auProperties -Force
				Write-Host "CAM configuration file re-generated."

		        Write-Host "Redirecting ROOT to Cloud Access Manager."

                $redirectString = '<%response.sendRedirect("CloudAccessManager/login.jsp");%>'
				$targetDir = "$CatalinaBase\webapps\ROOT"
				$indexFileName = "$targetDir\index.jsp"

				if(-not (Test-Path $targetDir))
				{
					New-Item $targetDir -type directory
				}

				if(-not (Test-Path $indexFileName))
				{
					New-Item $indexFileName -type file
				}

				Set-Content $indexFileName $redirectString -Force



		        Write-Host "Pulling in Agent machine deployment script."

				$templateLoc = "$CatalinaHomeLocation\ARMtemplateFiles"
				
				if(-not (Test-Path $templateLoc))
				{
					New-Item $templateLoc -type directory
				}

				#clear out whatever was stuffed in from the deployment WAR file
				Remove-Item "$templateLoc\*" -Recurse
				
				copy "$LocalDLPath\$agentARM" $templateLoc
				copy "$LocalDLPath\$gaAgentARM" $templateLoc
				copy "$LocalDLPath\$linuxAgentARM" $templateLoc

			}
		}

        Script Install_Auth_file
        {
            DependsOn  = @("[Script]Install_AUI")

            GetScript  = { @{ Result = "Install_Auth_file" } }

            TestScript = {
				$targetDir = "$env:CATALINA_HOME\adminproperty"
				$authFilePath = "$targetDir\authfile.txt"
 
                return Test-Path $authFilePath -PathType Leaf
			}
            SetScript  = {


				Write-Host "Writing auth file."

# File format as documented here: https://github.com/Azure/azure-sdk-for-java/blob/master/AUTH.md


				$localAzureCreds = $using:AzureCreds   # can delete?
				$RGNameLocal     = $using:RGName       # can delete?
				$tenantID        = $using:tenantID

				Write-Host "Create auth file."
				

				$CAMDeploymentInfoCred = $using:CAMDeploymentInfo;
				$CAMDeploymentInfo = $CAMDeploymentInfoCred.GetNetworkCredential().Password
				$CAMDeploymenInfoJSONDecoded = [System.Web.HttpUtility]::UrlDecode($CAMDeploymentInfo)
				$CAMDeploymenInfoDecoded = ConvertFrom-Json $CAMDeploymenInfoJSONDecoded
				$authFileContent = [System.Web.HttpUtility]::UrlDecode($CAMDeploymenInfoDecoded.AzureAuthFile)
				
				$targetDir = "$env:CATALINA_HOME\adminproperty"
				$authFilePath = "$targetDir\authfile.txt"

				if(-not (Test-Path $authFilePath))
				{
					New-Item $authFilePath -type file
				}

				Set-Content $authFilePath $authFileContent -Force


				Write-Host "Update environment so AZURE_AUTH_LOCATION points to auth file."

				[System.Environment]::SetEnvironmentVariable("AZURE_AUTH_LOCATION", $authFilePath, "Machine")
				$env:AZURE_AUTH_LOCATION = $authFilePath



				#Get local version of passed-in credentials
				$localVMAdminCreds = $using:VMAdminCreds
				$VMAdminUsername = $localVMAdminCreds.GetNetworkCredential().Username

				$localDomainAdminCreds = $using:DomainAdminCreds
				$DomainAdminUsername = $localDomainAdminCreds.GetNetworkCredential().Username



				$kvId = $using:keyVaultId

				$rcSecretName = 'cloudAccessRegistrationCode'
				$djSecretName = 'domainJoinPassword'

				$laSecretName = 'localAdminPassword'


				################################


				Write-Host "Creating default template parameters file data"


				$armParamContent = @"
{
    "`$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
		"vmSize": { "value": "%vmSize%" },
        "CAMDeploymentBlobSource": { "value": "$using:sourceURI" },
        "existingSubnetName": { "value": "$using:existingSubnetName" },
        "domainUsername": { "value": "$DomainAdminUsername" },
        "domainPassword": {
			"reference": {
			  "keyVault": {
				"id": "$kvId"
			  },
			  "secretName": "$djSecretName"
			}		
		},
        "registrationCode": {
			"reference": {
			  "keyVault": {
				"id": "$kvId"
			  },
			  "secretName": "$rcSecretName"
			}
		},
        "dnsLabelPrefix": { "value": "tbd-vmname" },
        "existingVNETName": { "value": "$using:existingVNETName" },
        "vmAdminUsername": { "value": "$VMAdminUsername" },
        "vmAdminPassword": {
			"reference": {
			  "keyVault": {
				"id": "$kvId"
			  },
			  "secretName": "$laSecretName"
			}
		},
        "domainToJoin": { "value": "$using:domainFQDN" },
        "domainGroupToJoin": { "value": "$using:domainGroupAppServersJoin" },
        "storageAccountName": { "value": "$using:storageAccountName" },
		"_artifactsLocation": { "value": "https://raw.githubusercontent.com/teradici/deploy/master/end-user-application-machines/new-agent-vm" }
    }
}

"@


				$standardArmParamContent = $armParamContent -replace "%vmSize%",$using:standardVMSize
				$graphicsArmParamContent = $armParamContent -replace "%vmSize%",$using:graphicsVMSize
				$linuxArmParamContent = $armParamContent -replace "%vmSize%",$using:standardVMSize

				Write-Host "Creating default template parameters files"

				#now make the default parameters filenames - same root name but different suffix as the templates
                $agentARM = $using:agentARM
                $gaAgentARM = $using:gaAgentARM
				$linuxAgentARM = $using:linuxAgentARM

				$agentARMparam = ($agentARM.split('.')[0]) + ".customparameters.json"
				$gaAgentARMparam = ($gaAgentARM.split('.')[0]) + ".customparameters.json"
				$linuxAgentARMparam = ($linuxAgentARM.split('.')[0]) + ".customparameters.json"

				$ParamTargetDir = "$using:CatalinaHomeLocation\ARMParametertemplateFiles"
				$ParamTargetFilePath = "$ParamTargetDir\$agentARMparam"
				$GaParamTargetFilePath = "$ParamTargetDir\$gaAgentARMparam"
				$LinuxParamTargetFilePath = "$ParamTargetDir\$linuxAgentARMparam"

				if(-not (Test-Path $ParamTargetDir))
				{
					New-Item $ParamTargetDir -type directory
				}

				#clear out whatever was stuffed in from the deployment WAR file
				Remove-Item "$ParamTargetDir\*" -Recurse

				# Standard Agent Parameter file
				if(-not (Test-Path $ParamTargetFilePath))
				{
					New-Item $ParamTargetFilePath -type file
				}

				Set-Content $ParamTargetFilePath $standardArmParamContent -Force


				# Graphics Agent Parameter file
				if(-not (Test-Path $GaParamTargetFilePath))
				{
					New-Item $GaParamTargetFilePath -type file
				}

				Set-Content $GaParamTargetFilePath $graphicsArmParamContent -Force

				# Linux Agent Parameter file
				if(-not (Test-Path $LinuxParamTargetFilePath))
				{
					New-Item $LinuxParamTargetFilePath -type file
				}

				Set-Content $LinuxParamTargetFilePath $linuxArmParamContent -Force

		        Write-Host "Finished Creating default template parameters file data."
            }
		}

		Script Setup_Broker_Service
        {
            DependsOn = @("[Script]Install_Tomcat", "[xRemoteFile]Download_Keystore")
            GetScript  = { @{ Result = "Setup_Broker_Service" } }

            TestScript = {
				return !!(Get-Service $using:brokerServiceName -ErrorAction SilentlyContinue)
			}
            SetScript  = {
				Write-Host "Configuring Tomcat for $using:brokerServiceName service"

				$catalinaHome = $using:CatalinaHomeLocation
				$catalinaBase = "$catalinaHome\$using:brokerServiceName"

                #set the current (temporary) environment
				$env:CATALINA_BASE = $catalinaBase

				# make new broker instance location - copying the directories specified
				# here: https://tomcat.apache.org/tomcat-8.0-doc/windows-service-howto.html

				# clear out any old cruft first
				Remove-Item "$catalinaBase" -Force -Recurse -ErrorAction SilentlyContinue
				Copy-Item "$catalinaHome\conf" "$catalinaBase\conf" -Recurse -ErrorAction SilentlyContinue
				Copy-Item "$catalinaHome\logs" "$catalinaBase\logs" -Recurse -ErrorAction SilentlyContinue
				Copy-Item "$catalinaHome\temp" "$catalinaBase\temp" -Recurse -ErrorAction SilentlyContinue
				Copy-Item "$catalinaHome\work" "$catalinaBase\work" -Recurse -ErrorAction SilentlyContinue

				# Make empty webapps directory if it does not exist. 
				New-Item -ItemType Directory -Force -Path "$catalinaBase\webapps"

				$serverXMLFile = $catalinaBase + '\conf\server.xml'
				$origServerXMLFile = $catalinaBase + '\conf\server.xml.orig'

				# back up server.xml file if not done in a previous round
				if( -not ( Get-Item ($origServerXMLFile) -ErrorAction SilentlyContinue ) )
				{
					Copy-Item -Path ($serverXMLFile) `
						-Destination ($origServerXMLFile)
				}

				# --------- update server.xml file ---------
				$xml = [xml](Get-Content ($origServerXMLFile))

				# Set the local server control port to something different than the default 8005 to enable the service to start.
				$xml.server.port = "8006"

				#remove unwanted default connectors
				($xml.Server.Service.Connector) | ForEach-Object { [void]$_.ParentNode.removeChild($_) }

				$NewConnector = [xml] ('<Connector
					port="'+$using:brokerPort+'"
					protocol="org.apache.coyote.http11.Http11NioProtocol"
					SSLEnabled="true"
					keystoreFile="'+$using:LocalDLPath+'\.keystore"
					maxThreads="2000" scheme="https" secure="true"
					clientAuth="false" sslProtocol="TLS"
					SSLEngine="on" keystorePass="changeit"
					SSLPassword="changeit"
					sslEnabledProtocols="TLSv1.0,TLSv1.1,TLSv1.2"
					ciphers="TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,TLS_RSA_WITH_AES_128_CBC_SHA"
					/>')

				$xml.Server.Service.InsertBefore(
					# new child
					$xml.ImportNode($NewConnector.Connector,$true),
					#ref child
					$xml.Server.Service.Engine )

				$xml.save($serverXMLFile)



				Write-Host "Opening port $using:brokerPort"

				#open port in firewall
				netsh advfirewall firewall add rule name="Open Port $using:brokerPort" dir=in action=allow protocol=TCP localport=$using:brokerPort

				# Install and start service for new config

				& "$using:CatalinaBinLocation\service.bat" install $using:brokerServiceName
				Write-Host "Tomcat Installer exit code: $LASTEXITCODE"
				Start-Sleep -s 10  #TODO: Is this sleep ACTUALLY needed?

				Write-Host "Setting Tomcat Service for $using:brokerServiceName to automatically startup."
				Set-Service $using:brokerServiceName -startuptype "automatic"
	        }
        }

		Script Install_Broker
        {
            DependsOn  = @("[xRemoteFile]Download_Broker_WAR", "[Script]Setup_Broker_Service")
            GetScript  = { @{ Result = "Install_Broker" } }

            TestScript = {
				$WARPath = "$using:CatalinaHomeLocation\$using:brokerServiceName\webapps\$using:brokerWAR"
 
                return Test-Path $WARPath -PathType Leaf
			}
            SetScript  = {
                Write-Verbose "Install_Broker"

				$catalinaHome = $using:CatalinaHomeLocation
				$catalinaBase = "$catalinaHome\$using:brokerServiceName"

				copy "$using:LocalDLPath\$using:brokerWAR" ($catalinaBase + "\webapps")

				# $svc = get-service $using:brokerServiceName
				# if ($svc.Status -ne "Stopped") {$svc.stop()}

				Write-Host "Generating broker configuration file."
				$targetDir = $catalinaBase + "\brokerproperty"
				$cbPropertiesFile = "$targetDir\connectionbroker.properties"

				if(-not (Test-Path $targetDir))
				{
					New-Item $targetDir -type directory
				}

				if(-not (Test-Path $cbPropertiesFile))
				{
					New-Item $cbPropertiesFile -type file
				}

				#making another copy in catalinaHome until the paths are figured out...
				Write-Host "Generating broker configuration file in CatalinaHome."
				$targetDir = $catalinaHome + "\brokerproperty"
				$cbHomePropertiesFile = "$targetDir\connectionbroker.properties"

				if(-not (Test-Path $targetDir))
				{
					New-Item $targetDir -type directory
				}

				if(-not (Test-Path $cbHomePropertiesFile))
				{
					New-Item $cbHomePropertiesFile -type file
				}


				$firstIPv4IP = Get-NetIPAddress | Where-Object {$_.AddressFamily -eq "IPv4"} | select -First 1
				$ipaddressString = $firstIPv4IP.IPAddress

				$localAdminCreds = $using:DomainAdminCreds
				$adminUsername = $localAdminCreds.GetNetworkCredential().Username
				$adminPassword = $localAdminCreds.GetNetworkCredential().Password


				$cbProperties = @"
ldapHost=ldaps://$Using:dcvmfqdn
ldapAdminUsername=$adminUsername
ldapAdminPassword=$adminPassword
ldapDomain=$Using:domainFQDN
brokerHostName=$Using:pbvmfqdn
brokerProductName=CAS Connection Broker
brokerPlatform=$Using:family
brokerProductVersion=1.0
brokerIpaddress=$ipaddressString
brokerLocale=en_US
"@

				Set-Content $cbPropertiesFile $cbProperties
				Set-Content $cbHomePropertiesFile $cbProperties
				Write-Host "Broker configuration file generated."

				#----- setup security trust for LDAP certificate from DC -----

				#second, get the certificate file

				$ldapCertFileName = "ldapcert.cert"
				$certStoreLocationOnDC = "c:\" + $ldapCertFileName

				$issuerCertFileName = "issuercert.cert"
				$issuerCertStoreLocationOnDC = "c:\" + $issuerCertFileName

				$certSubject = "CN=$using:dcvmfqdn"

				Write-Host "Looking for cert with $certSubject on $dcvmfqdn"

				$foundCert = $false
				$loopCountRemaining = 180
				#loop until it's created
				while(-not $foundCert)
				{
					Write-Host "Waiting for LDAP certificate. Seconds remaining: $loopCountRemaining"

					$DCSession = New-PSSession $using:dcvmfqdn -Credential $using:DomainAdminCreds

					$foundCert = `
						Invoke-Command -Session $DCSession -ArgumentList $certSubject, $certStoreLocationOnDC, $issuerCertStoreLocationOnDC `
						  -ScriptBlock {
								$cs = $args[0]
								$cloc = $args[1]
								$icloc = $args[2]

				  				$cert = get-childItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Subject -eq $cs }
								if(-not $cert)
								{
									Write-Host "Did not find LDAP certificate."
									#maybe a certutil -pulse will help?
									# NOTE - must redirect stdout to $null otherwise the success return here pollutes the return value of $foundCert
									& "certutil" -pulse > $null
									return $false
								}
								else
								{
									Export-Certificate -Cert $cert -filepath  $cloc -force
									Write-Host "Exported LDAP certificate."

									#Now export issuer Certificate
									$issuerCert = get-childItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Subject -eq $cert.Issuer }
									Export-Certificate -Cert $issuerCert -filepath  $icloc -force

									return $true
								}
							}

					if(-not $foundCert)
					{
						Start-Sleep -Seconds 10
						$loopCountRemaining = $loopCountRemaining - 1
						if ($loopCountRemaining -eq 0)
						{
							Remove-PSSession $DCSession
							throw "No LDAP certificate!"
						}
					}
					else
					{
						#found it! copy
						Write-Host "Copying certs and exiting DC Session"
						Copy-Item -Path $certStoreLocationOnDC -Destination "$env:systemdrive\$ldapCertFileName" -FromSession $DCSession
						Copy-Item -Path $issuerCertStoreLocationOnDC -Destination "$env:systemdrive\$issuerCertFileName" -FromSession $DCSession
					}
					Remove-PSSession $DCSession
				}

				# Have the certificate file, add to keystore

                # keytool seems to be causing an error but succeeding. Ignore and continue.
                $eap = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
				& "keytool" -import -file "$env:systemdrive\$issuerCertFileName" -keystore ($env:classpath + "\security\cacerts") -storepass changeit -noprompt
                $ErrorActionPreference = $eap

		        Write-Host "Finished importing LDAP certificate to keystore."
            }
		}
		
		Script RegisterCam
		{
			DependsOn  = @("[Script]Install_Auth_file", "[Script]Install_Broker")  # depends on both services being installed to ensure the reboot at the end will start both services properly.
			GetScript  = { @{ Result = "RegisterCam" } }

            TestScript = { 

				if ( $env:CAM_USERNAME -and $env:CAM_PASSWORD -and $env:CAM_TENANTID -and $env:CAM_URI -and $env:CAM_DEPLOYMENTID)
				{
					return $true
				} else {
					return $false
				}
			}

            SetScript  = {
				##

				$CAMDeploymentInfoCred = $using:CAMDeploymentInfo;
				$CAMDeploymentInfo = $CAMDeploymentInfoCred.GetNetworkCredential().Password
				$CAMDeploymenInfoJSONDecoded = [System.Web.HttpUtility]::UrlDecode($CAMDeploymentInfo)
				$CAMDeploymenInfoDecoded = ConvertFrom-Json $CAMDeploymenInfoJSONDecoded
				$regInfo = $camDeploymenInfoDecoded.RegistrationInfo

				# now have an object with key value pairs - set environment to be active after reboot
				$regInfo.psobject.properties | Foreach-Object {
					[System.Environment]::SetEnvironmentVariable($_.Name, $_.Value, "Machine")
				}

				# Reboot machine to ensure all changes are picked up by all services.
				$global:DSCMachineStatus = 1
			}
		}
    }
}

