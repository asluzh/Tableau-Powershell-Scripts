##############################################
#    
#   Module: Tableau-REST.psm1
#   Description: Tableau REST API through Powershell
#   Version: 3.4
#   Author: Glen Robinson (glen.robinson@interworks.co.uk)
#
###############################################

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$global:api_ver = '3.4'
$global:chunkSize = 2097152	   ## 2MB or 2048KB

$Source = @"
using System.Net;
public class ExtendedWebClient : WebClient
{
public int Timeout;
public bool KeepAlive;
protected override WebRequest GetWebRequest(System.Uri address)
{
HttpWebRequest request = (HttpWebRequest)base.GetWebRequest(address);
if (request != null)
{
request.Timeout = Timeout;
request.KeepAlive = KeepAlive;
request.Proxy = null;
}
return request;
}
public ExtendedWebClient()
{
Timeout = 600000; // Timeout value by default
KeepAlive = false;
}
}
"@;
Add-Type -TypeDefinition $Source -Language CSharp

### SIGN IN AND SIGN OUT 

function TS-ServerInfo
{
 try
  {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/serverinfo -Method Get
   $api_Ver = $response.tsResponse.ServerInfo.restApiVersion
   $ProductVersion = $response.tsResponse.ServerInfo.ProductVersion.build
   "API Version: " + $api_Ver
   "Tableau Version: " + $ProductVersion
   $global:api_ver = $api_Ver
  }
  catch  
   {
     $global:api_ver = '3.4'
   }
}


function TS-SignIn
{

 param(
 [string[]] $server,
 [string[]] $username,
 [string[]] $password,
 [validateset('http','https')][string[]] $protocol = 'http',
 [string[]] $siteID = "",
 [string[]] $passwordfile =""
 )

 if ($passwordfile -ne '')
   {
    $encryptedCred = Get-Content $passwordfile | ConvertTo-SecureString
    $cred = New-Object System.management.Automation.PsCredential($username, $encryptedCred)
    $password = $cred.GetNetworkCredential().Password
   }
 
 $global:password = $password
 $global:server = $server
 $global:protocol = $protocol
 $global:username = $username
 TS-ServerInfo

 # generate body for sign in
 $signin_body = ('<tsRequest>
  <credentials name="' + $username + '" password="'+ $password + '" >
   <site contentUrl="' + $siteID +'"/>
  </credentials>
 </tsRequest>')

 try
  {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/auth/signin -Body $signin_body -Method Post
   # get the auth token, site id and my user id
   $global:authToken = $response.tsResponse.credentials.token
   $global:siteID = $response.tsResponse.credentials.site.id
   $global:myUserID = $response.tsResponse.credentials.user.id

   # set up header fields with auth token
   $global:headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
   # add X-Tableau-Auth header with our auth tokents-
   $headers.Add("X-Tableau-Auth", $authToken)
   "Signed In Successfully to Server: "  + ${protocol}+"://"+$server
   return '200'
  }

 catch {#throw "Unable to Sign-In to Tableau Server: " + ${protocol}+"://"+$server + " :- " + $_.Exception.Message}
  "Unable to Sign-In to Tableau Server: " + ${protocol}+"://"+$server
    "StatusCode: " + $_.Exception.Response.StatusCode.value__
    "StatusDescription: " + $_.Exception.Response.StatusDescription
  return $_.Exception.Response.StatusCode.value__
  }
}


function TS-SignOut
{
 try
 {
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/auth/signout -Headers $headers -Method Post
  "Signed Out Successfully from: " + ${protocol}+ "://"+$server
  }
 catch 
  {"Unable to Sign out from Tableau Server: " + ${protocol}+"://"+$server + " :- " + $_.Exception.Message}
}


### Project Management


function TS-QueryProjects
{

  param
  (
   [string[]] $Filter =""
   )

    if ($Filter -ne '') {$Filter += "&filter="+ $Filter }

 try
 {
 
   $PageSize = 100
   $PageNumber = 1
   $done = 'FALSE'

   While ($done -eq 'FALSE')
   {
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects?$filter`&pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

     $PageNumber += 1

     ForEach ($detail in $response.tsResponse.Projects.Project)
      { 
        $owner = TS-GetUserDetails -ID $detail.owner.id
        $Projects = [pscustomobject]@{Name=$detail.name; Description = $detail.description; CreatedAt = $detail.createdAt; UpdatedAt = $detail.updatedAt; ContentPermissions = $detail.contentPermissions; Owner= $Owner; ID=$detail.id}
        $Projects
      }
   }
 } 
 catch {"Unable to query Projects"}
}

function TS-CreateProject
{
 param(
  [string[]] $ProjectName = "",
  [string[]] $Description = "",
  [string[]] $ParentProject = "",
  [string[]] $ParentProjectID = "",
  [validateset('ManagedByOwner','LockedToProject')][string[]] $ContentPermissions = "LockedToProject"
 )

 try
 {
  if ($ParentProjectID -ne ''){$ParentProjectID} else {$ParentProjectID = TS-GetProjectDetails -ProjectName $ParentProject}
  if ($ParentProjectID.Length -gt 0){$parentprojectDetails = ' parentProjectId ="'+ $ParentProjectID +'"'} else {$parentprojectDetails = ""}

  $request_body = ('<tsRequest><project ' + $parentprojectDetails + ' name="' + $ProjectName +'" description="'+ $Description + '" contentPermissions="' +$ContentPermissions +'"/></tsRequest>')
  $request_body
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects -Headers $headers -Method POST -Body $request_body
  $response.tsResponse.project
 } 
 catch {"Unable to create Project: " + $ProjectName + " :- " + $_.Exception.Message}
}

function TS-UpdateProject
{
 param(
  [string[]] $ProjectName,
  [string[]] $NewProjectName = "",
  [string[]] $Description = "",
  [string[]] $NewParentProject = "",
  [string[]] $NewParentProjectID = "",
  [validateset('ManagedByOwner','LockedToProject')][string[]] $ContentPermissions = ""
 )
 try
 {
  $ProjectID= TS-GetProjectDetails -projectname $ProjectName

  if ($NewParentProjectID -ne ''){$NewParentProjectID} else {$NewParentProjectID = TS-GetProjectDetails -ProjectName $NewParentProject}
  if ($NewParentProjectID.Length -gt 0){$parentproject = ' parentProjectId ="'+ $NewParentProjectID +'"'} else {$parentproject = ""}
  if ($NewProjectName -ne '') {$projectname_body = ' name ="'+ $NewProjectname +'"'} else {$projectname_body = ""} 
  if ($Description -ne '') {$description_body = ' description ="'+ $Description +'"'} else { $description_body = ""}
  if ($ContentPermissions -ne '') {$Permissions_body = ' contentPermissions ="'+ $ContentPermissions +'"'} else { $Permissions_body = ""}
 
  $request_body = ('<tsRequest><project' + $parentproject + $projectname_body + $description_body + $Permissions_body + ' /></tsRequest>')
  $request_body
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID -Headers $headers -Method Put -Body $request_body

  ForEach ($detail in $response.tsResponse.Project)
      { 
        $ParentProject = TS-GetProjectDetails -ProjectID $detail.parentProjectID
        $Project = [pscustomobject]@{Name=$detail.name; ParentProject = $ParentProject ;ParentProjectID = $detail.parentProjectID ;Description = $detail.description; CreatedAt = $detail.createdAt; UpdatedAt = $detail.updatedAt; ContentPermissions = $detail.contentPermissions; ID=$detail.id}
        $Project
      }
 }
 catch {"Unable to Update Project: " + $ProjectName + " :- " + $_.Exception.Message}

}

function TS-DeleteProject
{
 param(
  [string[]] $ProjectName
  )
  try
  {
   $ProjectID= TS-GetProjectDetails -projectname $ProjectName
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID -Headers $Headers -Method Delete
   $response.tsResponse
  }
  catch {"Unable to delete Project: "+$ProjectName  + " :- " + $_.Exception.Message}
}

function TS-GetProjectDetails
{
 param(
 [string[]] $ProjectName = "",
 [string[]] $ProjectID = ""
 )
 
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   {
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

     $PageNumber += 1

     foreach ($project_detail in $response.tsResponse.Projects.Project)
     { 
      if ($projectName -eq $project_detail.name){Return $Project_detail.ID}
      if ($projectID -eq $project_detail.ID){Return $Project_detail.Name}
     }
   }
}


#### Site Management

function TS-QuerySites
{
 try
 {
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   {
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

     $PageNumber += 1
     $response.tsresponse.Sites.site
   }
 }
 catch {"Unable to Query Sites." + " :- " + $_.Exception.Message}
}

function TS-QuerySite
{
 try
 {
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID -Headers $headers -Method Get
  $response.tsResponse.Site
 }
 catch {"Unable to Query Site."}
}

function TS-UpdateSite
{
 param(
  [string[]] $NewSiteName = "",
  [string[]] $NewSiteID = "",
  [validateset('ContentAndUsers','ContentOnly')][string[]] $AdminMode = "",
  [string[]] $UserQuota = "",
  [string[]] $StorageQuota = "",
  [string[]] $RevisionLimit = "",
  [validateset('true','false')][string[]] $RevisionHistoryEnabled = "",
  [validateset('true','false')][string[]] $DisableSubscriptions = "",
  [validateset('true','false')][string[]] $SubcribeOthersEnabled = "",
  [validateset('true','false')][string[]] $FlowsEnabled = "",
  [validateset('true','false')][string[]] $GuestAccessEnabled = "",
  [validateset('true','false')][string[]] $CacheWarmupEnabled = "",
  [validateset('true','false')][string[]] $CommentingEnabled = ""
  #[string[]] $CreatorCapacity="",
  #[string[]] $ExplorerCapacity="",
  #[string[]] $ViewerCapacity=""


 )

# try
# {
  $body = ""
  if ($NewSiteName -ne '') {$body += ' name ="'+ $NewSitename +'"'}
  if ($NewSiteID -ne '') {$body += ' contentUrl ="'+ $NewSiteID +'"'}
  if ($AdminMode -ne '') {$body += ' adminMode ="'+ $AdminMode +'"'}
  if ($UserQuota -ne '') {$body += ' userQuota ="'+ $UserQuota +'"'}
  if ($StorageQuota -ne '') {$body += ' storageQuota ="'+ $StorageQuota +'"'}
  if ($DisableSubscriptions -ne '') {$body += ' disableSubscriptions ="'+ $DisableSubscriptions +'"'}
  if ($FlowsEnabled -ne '') {$body += ' flowsEnabled ="'+ $FlowsEnabled +'"'}
  if ($GuestAccessEnabled -ne '') {$body += ' guestAccessEnabled ="'+ $GuestAccessEnabled +'"'}
  if ($CacheWarmupEnabled -ne '') {$body += ' cacheWarmupEnabled ="'+ $CacheWarmupEnabled +'"'}
  if ($CommentingEnabled -ne '') {$body += ' commentingEnabled ="'+ $CommentingEnabled +'"'}
  if ($RevisionHistoryEnabled -ne '') {$body += ' revisionHistoryEnabled ="'+ $RevisionHistoryEnabled +'"'}
  if ($SubcribeOthersEnabled -ne '') {$body += ' subcribeOthersEnabled ="'+ $SubcribeOthersEnabled +'"'}
  if ($RevisionLimit -ne '') {$body += ' revisionLimit ="'+ $RevisionLimit +'"'}
#  if ($CreatorCapacity -ne '') {$body += ' tierCreatorCapacity ="'+ $TierCreatorCapacity +'"'}
#  if ($ExplorerCapacity -ne '') {$body += ' tierExplorerCapacity ="'+ $TierExplorerCapacity +'"'}
#  if ($ViewerCapacity -ne '') {$body += ' tierViewerCapacity ="'+ $TierViewerCapacity +'"'}

  $body = ('<tsRequest><site' + $body +  ' /></tsRequest>')
  $body
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID -Headers $headers -Method Put -Body $body
  $response.tsResponse.Site
 #}
 #catch{"Problem updating Site: " + $SiteName + " :- " + $_.Exception.Message }
}


function TS-CreateSite
{
 param(
  [string[]] $SiteName = "",
  [string[]] $SiteID = "",
  [validateset('ContentAndUsers','ContentOnly')][string[]] $AdminMode = "",
  [string[]] $UserQuota = "",
  [string[]] $StorageQuota = "",
  [string[]] $RevisionLimit = "",
  [validateset('Active','Suspended')][string[]] $State = "",
  [validateset('true','false')][string[]] $RevisionHistoryEnabled = "",
  [validateset('true','false')][string[]] $DisableSubscriptions = "",
  [validateset('true','false')][string[]] $SubcribeOthersEnabled = "",
  [validateset('true','false')][string[]] $FlowsEnabled = "",
  [validateset('true','false')][string[]] $GuestAccessEnabled = "",
  [validateset('true','false')][string[]] $CacheWarmupEnabled = "",
  [validateset('true','false')][string[]] $CommentingEnabled = ""
  #[string[]] $CreatorCapacity="",
  #[string[]] $ExplorerCapacity="",
  #[string[]] $ViewerCapacity=""
 )
 
 try
 {
  $body = ""
  if ($SiteName -ne '') {$body += ' name ="'+ $Sitename +'"'}
  if ($SiteID -ne '') {$body += ' contentUrl ="'+ $SiteID +'"'}
  if ($State -ne '') {$body += ' state ="'+ $State +'"'}
  if ($AdminMode -ne '') {$body += ' adminMode ="'+ $AdminMode +'"'}
  if ($UserQuota -ne '') {$body += ' userQuota ="'+ $UserQuota +'"'}
  if ($StorageQuota -ne '') {$body += ' storageQuota ="'+ $StorageQuota +'"'}
  if ($DisableSubscriptions -ne '') {$body += ' disableSubscriptions ="'+ $DisableSubscriptions +'"'}
  if ($FlowsEnabled -ne '') {$body += ' flowsEnabled ="'+ $FlowsEnabled +'"'}
  if ($GuestAccessEnabled -ne '') {$body += ' guestAccessEnabled ="'+ $GuestAccessEnabled +'"'}
  if ($CacheWarmupEnabled -ne '') {$body += ' cacheWarmupEnabled ="'+ $CacheWarmupEnabled +'"'}
  if ($CommentingEnabled -ne '') {$body += ' commentingEnabled ="'+ $CommentingEnabled +'"'}
  if ($RevisionHistoryEnabled -ne '') {$body += ' revisionHistoryEnabled ="'+ $RevisionHistoryEnabled +'"'}
  if ($SubcribeOthersEnabled -ne '') {$body += ' subcribeOthersEnabled ="'+ $SubcribeOthersEnabled +'"'}
  if ($RevisionLimit -ne '') {$body += ' revisionLimit ="'+ $RevisionLimit +'"'}
 # if ($CreatorCapacity -ne '') {$body += ' tierCreatorCapacity ="'+ $TierCreatorCapacity +'"'}
 # if ($ExplorerCapacity -ne '') {$body += ' tierExplorerCapacity ="'+ $TierExplorerCapacity +'"'}
 # if ($ViewerCapacity -ne '') {$body += ' tierViewerCapacity ="'+ $TierViewerCapacity +'"'}

  $body = ('<tsRequest><site' + $body +  ' /></tsRequest>')
  $body
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites -Headers $headers -Method POST -Body $body
  $response.tsResponse.Site
 }
 catch{"Problem Creating Site: " + $SiteName + " :- " + $_.Exception.Message}
}

function TS-SwitchSite
{
 param(
 [string[]] $SiteID = ""
 )
 try
  { 
   $body = ('<tsRequest>
   <site contentUrl="' + $siteID +'"/>
   </tsRequest>')

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/auth/switchSite -Headers $headers -Method POST -Body $body
    $global:authToken = $response.tsResponse.credentials.token
    $global:siteID = $response.tsResponse.credentials.site.id
    $global:myUserID = $response.tsResponse.credentials.user.id

    # set up header fields with auth token
    $global:headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    # add X-Tableau-Auth header with our auth tokents-
    $headers.Add("X-Tableau-Auth", $authToken)
    "Successfully switched to Site: "  + $siteID
  
  }
 Catch {"Unable to Change to Site: " + $SiteID }
}

function TS-DeleteSite
{
 param ([validateset('Yes','No')][string[]] $AreYouSure = "No")
 if ($AreYouSure -eq "Yes")
 {
  try
   {
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID -Headers $Headers -Method Delete
    $response.tsResponse
   }
   catch {"Unable to delete Site." + " :- " + $_.Exception.Message}
 }
}

### Groups Management


function TS-CreateGroup
{
  param(
 [string[]] $GroupName = "",
 [string[]] $DomainName = "",
 [validateset('Creator', 'Explorer', 'ExplorerCanPublish', 'SiteAdministratorExplorer', 'SiteAdministratorCreator', 'Unlicensed', 'Viewer')][string[]] $SiteRole = "Unlicensed",
 [validateset('true', 'false')][string[]] $BackgroundTask = "false"
 )
 try
 {
   if (-not($DomainName)) 
    { # Local Group Creation
      $body = ('<tsRequest><group name="' + $GroupName +  '" /></tsRequest>')
      $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups -Headers $headers -Method POST -Body $body
      $response.tsResponse.group
    }
   else
    {  # Active Directory Group Creation

      $body = ('<tsRequest><group name="' + $GroupName + '" ><import source="ActiveDirectory" domainName="' +$DomainName + '" siteRole="' + $SiteRole +'" /></group></tsRequest>')
      $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups?asJob=$BackgroundTask -Headers $headers -Method POST -Body $body
      $response.tsResponse.group
    }
  }
 catch {"Unable to Create Group: " + $GroupName + " :- " + $_.Exception.Message}
}


function TS-DeleteGroup
{
param(
  [string[]] $GroupName,
  [string[]] $DomainName ="local"

  )
  try
  {
   $GroupID = TS-GetGroupDetails -name $GroupName -Domain $DomainName
   $GRoupID

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups/$GroupID -Headers $Headers -Method Delete
   $response.tsResponse
  }
  catch {"Unable to delete Group: "+$GroupName + " :- " + $_.Exception.Message}
}

function TS-QueryGroups
{

  param
  (
   [string[]] $Filter ="")

    if ($Filter -ne '') {$Filter += "&filter="+ $Filter }

  try
   {
    $PageSize = 100
    $PageNumber = 1
    $done = 'FALSE'

    While ($done -eq 'FALSE')
    {
      $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups?$filter`&pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
      $totalAvailable = $response.tsResponse.pagination.totalAvailable

      If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}
      $PageNumber += 1

      ForEach ($detail in $response.tsResponse.Groups.Group)
       { 
        $Groups = [pscustomobject]@{Name=$detail.name; Domain=$detail.Domain.Name}
        $Groups
       }
    }
   }
  catch {"Unable to query Groups." + " :- " + $_.Exception.Message}
}


function TS-UpdateGroup
{
 param(
  [string[]] $GroupName,
  [string[]] $DomainName ="local",
  [string[]] $NewGroupName,
  [validateset('Creator', 'Explorer', 'ExplorerCanPublish', 'SiteAdministratorExplorer', 'SiteAdministratorCreator', 'Unlicensed', 'Viewer')][string[]] $SiteRole = "Unlicensed",
  [validateset('true', 'false')][string[]] $BackgroundTask = "false"
  )
  try
  {

   $GroupID = TS-GetGroupDetails -name $GroupName -Domain $DomainName
   $GRoupID

   if ($DomainName -eq "local") 
    { # Local Group Update
     $body = ('<tsRequest><group name="' + $NewGroupName +  '" /></tsRequest>')
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups/$GroupID -Headers $headers -Method PUT -Body $body
     $response.tsResponse.group
    }
   else
    {  # Active Directory Group Update

      $body = ('<tsRequest><group name="' + $GroupName + '" ><import source="ActiveDirectory" domainName="' +$DomainName + '" siteRole="' + $NewSiteRole +'" /></group></tsRequest>')
      $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups/$GroupID?asJob=$BackgroundTask -Headers $headers -Method PUT -Body $body
      $response.tsResponse.group
    }
  }
  catch {"Unable to Update Group: "+$GroupName + " :- " + $_.Exception.Message}
}

    
function TS-GetGroupDetails
{
 param(
 [string[]] $Name = "",
 [string[]] $ID = "",
 [string[]] $Domain ="local"
 )
 
 $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups -Headers $headers -Method Get

 foreach ($detail in $response.tsResponse.Groups.Group)
  { 
   if ($Name -eq $detail.name -and $Domain -eq $detail.Domain.Name){Return $detail.ID}
   if ($ID -eq $detail.ID)
   {
    $detail.Name 
    $detail.Domain.Name
   }
  }
}


### User Management

function TS-GetUsersOnSite
{ 

  param
  (
   [string[]] $Filter ="")

    if ($Filter -ne '') {$Filter += "&filter="+ $Filter }
 try
  {
   $PageSize = 100
   $PageNumber = 1
   $done = 'FALSE'

   While ($done -eq 'FALSE')
    {

    
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users?$filter`&pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}
     $PageNumber += 1
     $response.tsResponse.Users.User
    }
  }
  catch {"Unable to Get User List from Site :- " + $_.Exception.Message}
}

function TS-AddUserToGroup
{
 param(
  [string[]] $GroupName,
  [string[]] $UserAccount,
  [string[]] $UserID

  )
  try
  {
   $GroupID = TS-GetGroupDetails -name $GroupName
   $UserID  = TS-GetUserDetails -name $UserAccount
   if ($UserID -ne '') {$UserID} else { $UserID  = TS-GetUserDetails -name $UserAccount}

   $body = ('<tsRequest><user id="' + $UserID +  '" /></tsRequest>')
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups/$GroupID/users -Headers $headers -Method POST -Body $body
   $response.tsResponse.user
  }
  catch {"Unable to Add User "+ $UserAccount + " to Group: "+$GroupName + " :- " + $_.Exception.Message}
}


function TS-RemoveUserFromGroup
{
 param(
  [string[]] $GroupName,
  [string[]] $UserAccount
  )
  try
  {
   $GroupID = TS-GetGroupDetails -name $GroupName
   $UserID  = TS-GetUserDetails -name $UserAccount
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups/$GroupID/users/$UserID -Headers $headers -Method DELETE 
   "User Account: " + $UserAccount + " removed from Group: " + $GroupName
  }
  catch {"Unable to Remove User "+ $UserAccount + " from Group: "+$GroupName + " :- " + $_.Exception.Message}
}

function TS-RemoveUserFromSite
{
 param(
  [string[]] $UserAccount
  )
  try
  {
   $UserID  = TS-GetUserDetails -name $UserAccount
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users/$UserID -Headers $headers -Method DELETE 
   "User Account: " + $UserAccount + " removed from Site."
  }
  catch {"Unable to Remove User from Site: "+ $UserAccount + " :- " + $_.Exception.Message}
}


function TS-GetUserDetails
{
 param(
 [string[]] $name = "",
 [string[]] $ID = ""
 )
 
 if ($ID -ne '')
  {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users/$ID -Headers $headers -Method Get
   Return $response.tsResponse.User.Name
  }

 if ($name -ne '')
  {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users?filter=name:eq:$name -Headers $headers -Method Get
   Return $response.tsResponse.Users.User.ID
  }


 # $PageSize = 100
 # $PageNumber = 1
 # $done = 'FALSE'

 # While ($done -eq 'FALSE')
 #  {
 #   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
 #   $totalAvailable = $response.tsResponse.pagination.totalAvailable

  #  If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}
  #    $PageNumber += 1
  #    foreach ($detail in $response.tsResponse.Users.User)
  #     { 
  #      if ($Name -eq $detail.name){Return $detail.ID}
  #      if ($ID -eq $detail.ID){Return $detail.Name}
  #     }
  # }
}

function TS-GetUsersInGroup
{

param(
  [string[]] $GroupName,
  [string[]] $Domain ="Local"
  )
  try
  {
   $PageSize = 100
   $PageNumber = 1
   $done = 'FALSE'
   $GroupID = TS-GetGroupDetails -name $GroupName -Domain $Domain

   While ($done -eq 'FALSE')
    {
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/groups/$GroupID/users?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}
     $PageNumber += 1
     $response.tsResponse.Users.User
    }
  }
  catch {"Unable to Get Users in Group: "+$GroupName + " :- " + $_.Exception.Message}
}


function TS-QueryUser
{
 param(
  [string[]] $UserAccount
  )
  try
  {
   $UserID = TS-GetUserDetails -name $UserAccount
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users/$UserID -Headers $headers -Method GET 

   ForEach ($detail in $response.tsResponse.User)
       { 
        $User = [pscustomobject]@{ID=$detail.id; Name=$detail.name; SiteRole=$detail.siteRole; LastLogin=$detail.lastLogin; FullName=$detail.FullName; Domain=$detail.Domain.Name; externalAuthUserId=$detail.externalAuthUserID; authSetting=$detail.authSetting}
        $User
       }
  }
  catch
  {
  "Unable to Get User Information: "+$UserAccount + " :- " + $_.Exception.Message
  }
}

function TS-AddUserToSite
{
  param(
 [string[]] $UserAccount = "",
 [validateset('Creator', 'Explorer', 'ExplorerCanPublish', 'SiteAdministratorExplorer', 'SiteAdministratorCreator', 'Unlicensed', 'Viewer')][string[]] $SiteRole = "Unlicensed"
 
 )

 try
  {
   $body = ('<tsRequest><user name="' + $UserAccount +  '" siteRole="'+ $SiteRole +'"/></tsRequest>')
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users -Headers $headers -Method POST -Body $body
   $response.tsResponse.user
  }
  catch {"Unable to Create User: " + $UserAccount + " :- " + $_.Exception.Message}
}

function TS-UpdateUser
{
 param(
 [string[]] $UserAccount = "",
 [string[]] $Fullname = "",
 [string[]] $Password = "",
 [string[]] $Email = "",
 [validateset('Creator', 'Explorer', 'ExplorerCanPublish', 'SiteAdministratorExplorer', 'SiteAdministratorCreator', 'Unlicensed', 'Viewer')][string[]] $SiteRole = "Unlicensed"
 )
 
 try
   { 
    $UserID = TS-GetUserDetails -Name $UserAccount

    $body = ""
    if ($FullName -ne '') {$body += ' fullName ="'+ $FullName +'"'}
    if ($Password -ne '') {$body += ' password ="'+ $Password +'"'}
    if ($Email -ne '') {$body += ' email ="'+ $Email +'"'}
    if ($SiteRole -ne '') {$body += ' siteRole ="'+ $SiteRole +'"'}

    $body = ('<tsRequest><user' + $body +  ' /></tsRequest>')

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users/$UserID -Headers $headers -Method Put -Body $body
    $response.tsResponse.User
   }
   catch{"Problem updating User: " + $UserAccount + " :- " + $_.Exception.Message }
}


### DataSource Functions

function TS-QueryDataSources
{

  param
  (
   [string[]] $Filter ="")

    if ($Filter -ne '') {$Filter += "&filter="+ $Filter }

  try
  {

    $PageSize = 100
    $PageNumber = 1
    $done = 'FALSE'

    While ($done -eq 'FALSE')
    {
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources?$filter`&pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

     $PageNumber += 1

     ForEach ($detail in $response.tsResponse.datasources.datasource)
      {
       $owner = TS-GetUserDetails -ID $detail.owner.id
       $DataSources = [pscustomobject]@{Name=$detail.name; Project=$detail.project.name; Owner=$owner; CreatedAt=$detail.createdAt; UpdatedAt=$detail.updatedAt; ContentURL=$detail.ContentURL; Type=$detail.type; IsCertified=$detail.isCertified; EncryptExtracts=$detail.encryptExtracts; ID=$detail.ID}
       $DataSources
      }
    }
  }
  catch {"Unable to query DataSources :- " + $_.Exception.Message}
}


function TS-QueryDataSource
{
 param(
 [string[]] $DataSourceName = "",
 [string[]] $ProjectName = "",
 [string[]] $DataSourceID = ""
 )
 try
 {
    if ($DataSourceID -ne ''){$DataSourceID} else { $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName }
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID -Headers $headers -Method GET 

   ForEach ($detail in $response.tsresponse.datasource)
   {
    $owner = TS-GetUserDetails -ID $detail.owner.id
    $DataSource = [pscustomobject]@{ID=$detail.id; Name=$detail.name; Project=$detail.project.name; Owner=$owner; CreatedAt=$detail.createdAt; UpdatedAt=$detail.updatedAt; ContentURL=$detail.ContentURL; Type=$detail.type; Tags=$detail.tags.tag.label}
    $DataSource
   }
 }
 catch { "Unable to Query Data Source: " + $DataSourceName + " :- " + $_.Exception.Message}
}


function TS-QueryDataSourceConnections
{
  param(
  [string[]] $DataSourceName = "",
  [string[]] $ProjectName = "",
  [string[]] $DataSourceID = ""
  )
  try {
    if (!($DataSourceID)) { $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName }
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/connections -Headers $headers -Method GET 
    $response.tsResponse.Connections.connection
  }
  catch { "Unable to Query Data Source Connections: " + $DataSourceName + " :- " + $_.Exception.Message}
}

function TS-GetDataSourceDetails
{
 param(
 [string[]] $Name = "",
 [string[]] $ID = "",
 [string[]] $ProjectName = ""
 )
 
$PageSize = 100
$PageNumber = 1
$done = 'FALSE'

While ($done -eq 'FALSE')
 {
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
  $totalAvailable = $response.tsResponse.pagination.totalAvailable

  If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

  $PageNumber += 1

  foreach ($detail in $response.tsResponse.DataSources.DataSource)
   { 
    if ($Name -eq $detail.name -and $ProjectName -eq $detail.project.name){Return $detail.ID}
    if ($ID -eq $detail.ID){Return $detail.Name}
   }
 }
}


function TS-PublishDataSource
{
  param(
  [string[]] $ProjectName = "",
  [string[]] $DataSourceName = "",
  [string[]] $DataSourceFile = "",
  [string[]] $DataSourcePath = "",
  [string[]] $UserAccount = "",
  [string[]] $Password = "",
  [validateset('True', 'False')][string[]] $Embed = "",
  [validateset('True', 'False')][string[]] $OAuth = "", 
  [validateset('True', 'False')][string[]] $OverWrite = "false",
  [validateset('true', 'false')][string[]] $BackgroundTask = "false",
  [validateset('true', 'false')][string[]] $Append = "false",
  [validateset('true', 'false')][string[]] $Chunked = "True"
  )

  $project_ID = TS-GetProjectDetails -ProjectName $ProjectName
  $connectionCredentials = ""
  if ($UserAccount -ne '') {$connectionCredentials += ' name ="'+ $UserAccount +'"'}
  if ($Password -ne '') {$connectionCredentials += ' password ="'+ $Password +'"'}
  if ($Embed -ne '') {$connectionCredentials += ' embed ="'+ $Embed +'"'}
  if ($OAuth -ne '') {$connectionCredentials += ' oAuth ="'+ $OAuth +'"'} 
  if ($connectionCredentials -ne ''){$connectionCredentials = '<connectionCredentials'+ $connectionCredentials + ' />'}

  if ($Chunked -eq 'true') {
    try {
      $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/fileUploads -Headers $headers -Method POST
      $uploadSessionId = $response.tsResponse.fileUpload.uploadSessionId
    } catch {
      throw "Unable to publish Data Source (Stage 1) " + $DataSourceName + " :- " + $_.Exception.Message
    }

    $path = $DataSourcePath.trim() +"\"+ $DataSourceFile.trim()
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($path)
    $directory = [System.IO.Path]::GetDirectoryName($path)
    $extension = [System.IO.Path]::GetExtension($path)

    $fileItem = Get-Item $path
    $totalChunks = [int][Math]::Max(1,($fileItem.Length / $chunkSize))
    $count = 0
    $fn = [System.Net.WebUtility]::UrlEncode($fileName + $extension)
    $fileStream = [System.IO.File]::OpenRead($path)
    $chunk = New-Object byte[] $chunkSize

    $startTime = Get-Date
    while ( $bytesRead = $fileStream.Read($chunk, 0, $chunkSize) ) {
      try {
        $arrRead = $chunk[0..($bytesRead-1)]
        $output=[System.Text.Encoding]::Default.GetString($arrRead)
        $request_body = '
--12f71d3d4ae441caa0b38a5d4e0bde5e
Content-Disposition: name="request_payload"
Content-Type: text/xml


--12f71d3d4ae441caa0b38a5d4e0bde5e
Content-Disposition: name="tableau_file"; filename="' + $fn + '"
Content-Type: application/octet-stream

' + $output + '
--12f71d3d4ae441caa0b38a5d4e0bde5e--
'
        $wc = New-Object ExtendedWebClient
        $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
        $wc.Headers.Add('ContentLength', $request_body.Length)
        $wc.Headers.Add('Content-Type', 'multipart/mixed; boundary=12f71d3d4ae441caa0b38a5d4e0bde5e')
        $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/fileUploads/" +$uploadSessionId

        $status = (($count/$totalChunks)*100)
        $state = [int]$status
        if ($totalChunks -gt 1) { Write-Progress -Activity "Publishing data source: $DataSourceName" -Status "Uploading $state% $estTimeText" -PercentComplete $status }

        $response = $wc.UploadString($url ,'PUT', $request_body)
        $endTime = Get-Date
        $estTime = ((($endTime-$startTime).TotalSeconds*($totalChunks-($count+1))/($count+1) + $estTime)/2)
        if ($count -ge $totalChunks/5) {
          $estTimeMin = [Math]::Floor($estTime/60)
          $estTimeSec = [Math]::Ceiling($estTime%60)
          if ($estTimeMin -gt 0) { $estTimeText = ("${estTimeMin}m ${estTimeSec}s remaining").PadLeft(20) }
          else { $estTimeText = ("$estTimeSec sec remaining").PadLeft(20) }
          }
      } catch {
        throw "Unable to publish Data Source (Stage 2) " + $DataSourceName + " :- " + $_.Exception.Message
      }
      $count++
    }
    $fileStream.Close()

    if ($totalChunks -gt 1) {
      $state = 100
      Write-Progress -Activity "Publishing data source: $DataSourceName" -Status "Uploading $state%" -PercentComplete $state
      Start-Sleep -m 100
      Write-Progress -Activity "Publishing data source: $DataSourceName" -Status "Uploaded $state%" -Completed
      Start-Sleep -m 100
    }
    
    try {
      $enc_DataSourceName = [System.Net.WebUtility]::HtmlEncode($DataSourceName)
      $request_body = '
--6691a87289ac461bab2c945741f136e6
Content-Disposition: name="request_payload"
Content-Type: text/xml

<tsRequest>
    <datasource name="' + $enc_DataSourceName + '" >
    ' + $connectionCredentials + '
    <project id="' + $project_ID + '" />
  </datasource>
</tsRequest>
--6691a87289ac461bab2c945741f136e6--
'
      $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/datasources?uploadSessionId="+ $uploadSessionId +"&datasourceType="+ $extension.trimstart('.') +"&overwrite="+ $overwrite +"&append="+ $Append +"&asJob="+$BackgroundTask
      $wc = New-Object ExtendedWebClient
      $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
      $wc.Headers.Add('ContentLength', $request_body.Length)
      $wc.Headers.Add('Content-Type', 'multipart/mixed; boundary=6691a87289ac461bab2c945741f136e6')
      $response = $wc.UploadString($url ,'POST', $request_body)
      "Data Source " + $DataSourceName + " was successfully published to " + $ProjectName + " Project."
    } catch {
      throw "Unable to publish Data Source (Stage 3) " + $DataSourceName + " :- " + $_.Exception.Message
    }
  } else { # publish non-chunked
    try {
      $DS_Content = Get-Content $DataSourcePath\$DataSourceFile -Raw
      $request_body = '
--6691a87289ac461bab2c945741f136e6
Content-Disposition: name="request_payload"
Content-Type: text/xml

<tsRequest>
    <datasource name="' + $DataSourceName + '" >
    ' + $connectionCredentials + '
    <project id="' + $project_ID + '" />
  </datasource>
</tsRequest>
--6691a87289ac461bab2c945741f136e6
Content-Disposition: name="tableau_datasource"; filename="' + $DataSourceFile +'"
Content-Type:  application/octet-stream

' + $DS_Content + '
--6691a87289ac461bab2c945741f136e6--
'
      $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/datasources?overwrite=" +$overwrite + "&append="+$Append +"&asJob="+$BackgroundTask
    
      $wc = New-Object ExtendedWebClient
      $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
      $wc.Headers.Add('ContentLength', $request_body.Length)
      $wc.Headers.Add('Content-Type', 'multipart/mixed; boundary=6691a87289ac461bab2c945741f136e6')
      $response = $wc.UploadString($url ,'POST', $request_body)
      "Data Source " + $DataSourceName + " was successfully published to " + $ProjectName + " Project."
    } catch {
      throw "Unable to publish Data Source. " + $DataSourceName + " :- " + $_.Exception.Message
    }
  }
}


function TS-PublishWorkbook
{
  param(
  [string[]] $ProjectName = "",
  [string[]] $WorkbookName = "",
  [string[]] $WorkbookFile = "",
  [string[]] $WorkbookPath = "",
  [validateset('True', 'False')][string[]] $OverWrite = "false",
  [validateset('True', 'False')][string[]] $ShowTabs = "false",
  [validateset('true', 'false')][string[]] $BackgroundTask = "false",
  [validateset('true', 'false')][string[]] $Chunked = "True",
  [PSObject] $PublishViews
  )

  $project_ID = TS-GetProjectDetails -ProjectName $ProjectName
  $Views_Details = ""
  if ($PublishViews) {
     $Views_Details += "<views>"
     $PublishViews | ForEach-Object {
       $Views_Details += '<view name="'+$_.ViewName+'" hidden="'+$_.Hidden+'" />'
     }
     $Views_Details += "</views>"
  }

  if ($Chunked -eq 'true') {
    try {
      $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/fileUploads -Headers $headers -Method POST
      $uploadSessionId = $response.tsResponse.fileUpload.uploadSessionId
    } catch {
      throw "Unable to publish Workbook (Stage 1) " + $WorkbookName + " :- " + $_.Exception.Message
    }

    $path = $WorkbookPath.trim() +"\"+ $WorkbookFile.trim()
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($path)
    $directory = [System.IO.Path]::GetDirectoryName($path)
    $extension = [System.IO.Path]::GetExtension($path)

    $fileItem = Get-Item $path
    $totalChunks = [int][Math]::Max(1,($fileItem.Length / $chunkSize))
    $count = 0
    $fn = [System.Net.WebUtility]::UrlEncode($fileName + $extension)
    $fileStream = [System.IO.File]::OpenRead($path)
    $chunk = New-Object byte[] $chunkSize

    $startTime = Get-Date
    while ( $bytesRead = $fileStream.Read($chunk, 0, $chunkSize) ) {
      try {
        $arrRead = $chunk[0..($bytesRead-1)]
        $output=[System.Text.Encoding]::Default.GetString($arrRead)
        $request_body = '
--12f71d3d4ae441caa0b38a5d4e0bde5e
Content-Disposition: name="request_payload"
Content-Type: text/xml


--12f71d3d4ae441caa0b38a5d4e0bde5e
Content-Disposition: name="tableau_file"; filename="' + $fn + '"
Content-Type: application/octet-stream

' + $output + '
--12f71d3d4ae441caa0b38a5d4e0bde5e--
'
        $wc = New-Object ExtendedWebClient
        $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
        $wc.Headers.Add('ContentLength', $request_body.Length)
        $wc.Headers.Add('Content-Type', 'multipart/mixed; boundary=12f71d3d4ae441caa0b38a5d4e0bde5e')
        $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/fileUploads/" +$uploadSessionId

        $status = (($count/$totalChunks)*100)
        $state = [int]$status
        if ($totalChunks -gt 1) { Write-Progress -Activity "Publishing workbook: $WorkbookName" -Status "Uploading $state% $estTimeText" -PercentComplete $status }

        $response = $wc.UploadString($url ,'PUT', $request_body)
        $endTime = Get-Date
        $estTime = ((($endTime-$startTime).TotalSeconds*($totalChunks-($count+1))/($count+1) + $estTime)/2)
        if ($count -ge $totalChunks/5) {
          $estTimeMin = [Math]::Floor($estTime/60)
          $estTimeSec = [Math]::Ceiling($estTime%60)
          if ($estTimeMin -gt 0) { $estTimeText = ("${estTimeMin}m ${estTimeSec}s remaining").PadLeft(20) }
          else { $estTimeText = ("$estTimeSec sec remaining").PadLeft(20) }
        }
      } catch {
        throw "Unable to publish Workbook (Stage 2) " + $WorkbookName + " :- " + $_.Exception.Message
      }
      $count++
    }
    $fileStream.Close()

    if ($totalChunks -gt 1) {
        $state = 100
        Write-Progress -Activity "Publishing workbook: $WorkbookName" -Status "Uploading $state%" -PercentComplete $state
        Start-Sleep -m 100
        Write-Progress -Activity "Publishing workbook: $WorkbookName" -Status "Uploaded $state%" -Completed
        Start-Sleep -m 100
        }
    
    try {
      $enc_WorkbookName = [System.Net.WebUtility]::HtmlEncode($WorkbookName)
      $request_body = '
--6691a87289ac461bab2c945741f136e6
Content-Disposition: name="request_payload"
Content-Type: text/xml

<tsRequest>
  <workbook name="' + $enc_WorkbookName + '" showTabs="'+ $ShowTabs +'">
    <project id="' + $project_ID + '" />
    ' + $Views_Details + '
  </workbook>
</tsRequest>
--6691a87289ac461bab2c945741f136e6--
'
      $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/workbooks?uploadSessionId="+ $uploadSessionId +"&workbookType="+ $extension.trimstart('.') +"&overwrite="+$overwrite +"&asJob="+$BackgroundTask
      $wc = New-Object ExtendedWebClient
      $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
      $wc.Headers.Add('ContentLength', $request_body.Length)
      $wc.Headers.Add('Content-Type', 'multipart/mixed; boundary=6691a87289ac461bab2c945741f136e6')
      $response = $wc.UploadString($url ,'POST', $request_body)
      "Workbook " + $WorkbookName + " was successfully published to " + $ProjectName + " Project."
    } catch {
      throw "Unable to publish Workbook (Stage 3) " + $WorkbookName + " :- " + $_.Exception.Message
    }
  } else { #publish non-chunked
    try {
      $WB_Content = Get-Content $WorkbookPath\$WorkbookFile -Raw
      $request_body = '
--6691a87289ac461bab2c945741f136e6
Content-Disposition: name="request_payload"
Content-Type: text/xml

<tsRequest>
  <workbook name="' + $WorkbookName + '" showTabs="'+ $ShowTabs +'">
    <project id="' + $project_ID + '" />
    ' + $Views_Details + '
  </workbook>
</tsRequest>
--6691a87289ac461bab2c945741f136e6
Content-Disposition: name="tableau_workbook";filename="' + $WorkbookFile + '"
Content-Type: application/octet-stream

' + $WB_Content + '
--6691a87289ac461bab2c945741f136e6--'
      $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/workbooks?overwrite=" +$overwrite +"&asJob="+$BackgroundTask

      $wc = New-Object ExtendedWebClient
      $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
      $wc.Headers.Add('ContentLength', $request_body.Length)

      $wc.Headers.Add('Content-Type', 'multipart/mixed; boundary=6691a87289ac461bab2c945741f136e6')
      $response = $wc.UploadString($url ,'POST', $request_body)
      "Workbook " + $WorkbookName + " was successfully published to " + $ProjectName + " Project."
    } catch {
      throw "Unable to publish workbook " + $WorkbookName + " :- " + $_.Exception.Message
    }
  }
}



function TS-DeleteDataSource
{
  param(
  [string[]] $ProjectName = "",
  [string[]] $DataSourceName = "",
  [string[]] $DataSourceID = ""
  )
  try {
    if ($DataSourceID -ne ''){$DataSourceID} else {$DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID -Headers $headers -Method DELETE 
    "Data Source deleted: " + $DataSourceName
  }
  catch { "Unable to Delete Data Source: " + $DataSourceName + " :- " + $_.Exception.Message}
}


function TS-UpdateDataSource
{
  param(
  [string[]] $DataSourceName = "",
  [string[]] $ProjectName = "",
  [string[]] $NewProjectName = "",
  [string[]] $NewOwnerAccount = "",
  [string[]] $DataSourceID = ""
  )
  try {
    if ($DataSourceID -ne ''){ $DataSourceID} else { $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
    $userID = TS-GetUserDetails -name $NewOwnerAccount
    $ProjectID = TS-GetProjectDetails -ProjectName $NewProjectName

    $body = ""
    if ($NewProjectName -ne '') {$body += '<project id ="'+ $ProjectID +'" />'}
    if ($NewOwnerAccount -ne '') {$body += '<owner id ="'+ $userID +'"/>'}

    $body = ('<tsRequest><datasource>' + $body +  ' </datasource></tsRequest>')

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID -Headers $headers -Method Put -Body $body
    $response.tsResponse.datasource
  }
  catch { "Unable to Update Data Source: " + $DataSourceName + " :- " + $_.Exception.Message}
}

function TS-UpdateDataSourceConnection
{
  param(
  [string[]] $DataSourceName = "",
  [string[]] $ProjectName = "",
  [string[]] $ServerName = "",
  [string[]] $Port = "",
  [string[]] $UserName = "",
  [string[]] $Password = "",
  [validateset('True', 'False')][string[]] $embed = "",
  [string[]] $DataSourceID = ""
  )
  try {
    if (!($DataSourceID)) { $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
    $body = ""
    if ($ServerName -ne '') {$body += 'serverAddress ="'+ $ServerName +'" '}
    if ($Port -ne '') {$body += 'serverPort ="'+ $Port +'" '}
    if ($UserName -ne '') {$body += 'userName ="'+ $UserName +'" '}
    if ($Password -ne '') {$body += 'password ="'+ $Password +'" '}
    if ($embed -ne '') {$body += 'embedPassword ="'+ $embed +'" '}
   
    $body = ('<tsRequest><connection ' + $body +  '/></tsRequest>')
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/connection -Headers $headers -Method Put -Body $body
  }
  catch { "Unable to Update Data Source: " + $DataSourceName + " :- " + $_.Exception.Message}
}

function TS-UpdateWorkbookConnection
{
  param(
  [string[]] $WorkbookName = "",
  [string[]] $ProjectName = "",
  [string[]] $ServerName = "",
  [string[]] $Port = "",
  [string[]] $UserName = "",
  [string[]] $Password = "",
  [validateset('True', 'False')][string[]] $embed = "",
  [string[]] $WorkbookID = "",
  [string[]] $ConnectionID = ""
  )
  try {
    if (!($WorkbookID)) { $WorkbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
    $body = ""
    if ($ServerName -ne '') {$body += 'serverAddress ="'+ $ServerName +'" '}
    if ($Port -ne '') {$body += 'serverPort ="'+ $Port +'" '}
    if ($UserName -ne '') {$body += 'userName ="'+ $UserName +'" '}
    if ($Password -ne '') {$body += 'password ="'+ $Password +'" '}
    if ($embed -ne '') {$body += 'embedPassword ="'+ $embed +'" '}
   
    $body = ('<tsRequest><connection ' + $body +  '/></tsRequest>')
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/connections/$ConnectionID -Headers $headers -Method Put -Body $body
  }
  catch { "Unable to Update Workbook: " + $WorkbookName + " :- " + $_.Exception.Message}
}



###### PERMISSIONS


function TS-QueryProjectPermissions
{
param(
  [string[]] $ProjectName = ""
  )

 try
  {
   $ProjectID= TS-GetProjectDetails -projectname $ProjectName

   $content_types = ("Project","Workbook","DataSource")
   $content_locations = ("permissions","default-permissions/workbooks","default-permissions/datasources")
   $count = 0

   While($count -lt $content_types.Count) 
    {
     $location = $content_Locations[$count]
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/$location -Headers $headers -Method Get
 
     foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
      { 
       $Type = ""
       $GroupDomain = ""
       $ID = ""
       if($detail.group.id) 
        {
          $GroupDetails = TS-GetGroupDetails -ID $detail.group.id
          $GroupUser = $GroupDetails[0]
          $GroupDomain = $GroupDetails[1]

         #$GroupUser = TS-GetGroupDetails -ID $detail.group.id
         $Type = "Group"  
         $ID = $detail.group.id
        }

       if ($detail.user.id)
        {
         $GroupUser = TS-GetUserDetails -ID $detail.user.id
         $Type = "User" 
         $ID = $detail.user.id
        }
  
       foreach ($capability in $detail.capabilities.capability)
        {
         $Permissions = [pscustomobject]@{UserOrGroup = $GroupUser; Type = $Type; Domain = $GroupDomain; AffectedObject=$content_types[$count];Capability=$capability.name; Rights=$capability.mode; ID=$ID}
         $Permissions
        }
      }
     $count++
    }


   }
  catch{"Unable to query Project Permissions: " + $ProjectName + " :- " + $_.Exception.Message}
}


function TS-QueryWorkbookPermissions
{
param(
  [string[]] $ProjectName = "",
  [string[]] $WorkbookName = "",
 [string[]] $WorkbookID = ""
  )

 try
  {
   if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/permissions -Headers $headers -Method Get
 
     foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
      { 
       $Type = ""
       $GroupDomain = ""
       $ID = ""

       if($detail.group.id) 
        {
         $GroupDetails = TS-GetGroupDetails -ID $detail.group.id
         $GroupUser = $GroupDetails[0]
         $GroupDomain = $GroupDetails[1]
         $Type = "Group"  
         $ID = $detail.group.id
        }

       if ($detail.user.id)
        {
         $GroupUser = TS-GetUserDetails -ID $detail.user.id
         $Type = "User" 
         $ID = $detail.user.id
        }
  
       foreach ($capability in $detail.capabilities.capability)
        {
         $Permissions = [pscustomobject]@{UserOrGroup = $GroupUser; Domain = $GroupDomain; Type = $Type;Capability=$capability.name; Rights=$capability.mode; ID=$ID}
         $Permissions
        }
      }
   }
  catch{"Unable to query Workbook Permissions: " + $WorkbookName + " :- " + $_.Exception.Message }
}


function TS-QueryDataSourcePermissions
{
param(
  [string[]] $ProjectName = "",
  [string[]] $DataSourceName = "",
  [string[]] $DataSourceID = ""
  )

 try
  {
        if ($DataSourceID -ne ''){ $DataSourceID} else { $DataSourceID = TS-getDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/permissions -Headers $headers -Method Get
 
     foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
      { 
       $Type = ""
       $GroupDomain = ""
       $ID = ""

       if($detail.group.id) 
        {
          $GroupDetails = TS-GetGroupDetails -ID $detail.group.id
          $GroupUser = $GroupDetails[0]
          $GroupDomain = $GroupDetails[1]   
          $Type = "Group"  
          $ID = $detail.group.id
        }

       if ($detail.user.id)
        {
         $GroupUser = TS-GetUserDetails -ID $detail.user.id
         $Type = "User" 
         $ID = $detail.user.id
      
        }
  
       foreach ($capability in $detail.capabilities.capability)
        {
         $Permissions = [pscustomobject]@{UserOrGroup = $GroupUser; Domain = $GroupDomain;Type = $Type;Capability=$capability.name; Rights=$capability.mode;ID = $ID}
         $Permissions
        }
      }
   }
  catch{"Unable to query DataSources Permissions: " + $DataSourceName + " :- " + $_.Exception.Message }
}


function TS-QueryViewPermissions
{
param(
  [string[]] $ProjectName = "",
  [string[]] $WorkbookName = "",
  [string[]] $ViewName = "",
  [string[]] $ViewID = ""
  )

 try
  {
    if ($ViewID -ne '') {$ViewID} else {$ViewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName}

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views/$ViewID/permissions -Headers $headers -Method Get
 
     foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
      { 
       $Type = ""
       $GroupDomain = ""
       $ID = ""

       if($detail.group.id) 
        {
         $GroupDetails = TS-GetGroupDetails -ID $detail.group.id
         $GroupUser = $GroupDetails[0]
         $GroupDomain = $GroupDetails[1]
         $Type = "Group"  
         $ID = $detail.group.id
        }

       if ($detail.user.id)
        {
         $GroupUser = TS-GetUserDetails -ID $detail.user.id
         $Type = "User" 
         $ID = $detail.user.id
        }
  
       foreach ($capability in $detail.capabilities.capability)
        {
         $Permissions = [pscustomobject]@{UserOrGroup = $GroupUser; Domain = $GroupDomain; Type = $Type;Capability=$capability.name; Rights=$capability.mode; ID=$ID}
         $Permissions
        }
      }
   }
  catch{"Unable to query Workbook Permissions: " + $WorkbookName + " :- " + $_.Exception.Message }
}



function TS-UpdateProjectPermissions
{
param(
  [string[]] $ProjectName = "",
  [string[]] $GroupName = "",
  [string[]] $UserAccount = "",
  [string[]] $Domain ="local",

  #Project Permissions
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewProject = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SaveProject = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ProjectLeader = "",


    #Workbook Permissions
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadImagePDF = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadSummaryData = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewComments = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $AddComments = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $Filter = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadFullData = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ShareCustomized = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $WebEdit = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SaveWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $MoveWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DeleteWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SetWorkbookPermissions = "",

  #DataSource Permissions
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $Connect = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SaveDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DeleteDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SetDataSourcePermissions = "",
  [string[]] $UserID = "",
  [string[]] $GroupID = ""

 )

 try
 {

  $ProjectID= TS-GetProjectDetails -projectname $ProjectName
  if ($GroupName -ne '')
   {
    $GroupID = TS-GetGroupDetails -name $GroupName -Domain $Domain
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $UserID =''
   }

  if ($GroupID -ne '')
   {
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $UserID =''
   }

  if ($UserAccount -ne '')
   {
    $UserID = TS-GetUserDetails -name $UserAccount
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupId = ''
   }
  if ($UserID -ne '')
   {
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupID = ''
   }
  $GroupID
  $UserID
  $ProjectID

   # Check Existing Project Permissions

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/permissions -Headers $headers -Method Get

  foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
   { 
    if ($groupID -ne '' -and $groupID -eq $detail.group.id)
     {
       # Group is already permissioned against Project

      #"GroupID " + $GroupID
 
       # Check existing permissions
 
        ForEach ($permission in $detail.capabilities.capability)
           {
            
                if (($ViewProject -ne '' -and $permission.name -eq 'Read') -or ($SaveProject -ne '' -and $permission.name -eq 'Write') -or ($ProjectLeader -ne '' -and $permission.name -eq 'ProjectLeader'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/permissions/groups/$groupID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
            }
     } 

    if ($UserID -ne '' -and $UserID -eq $detail.user.id)
     {
       # User is already permissioned against Project

        ForEach ($permission in $detail.capabilities.capability)
           {
                if (($ViewProject -ne '' -and $permission.name -eq 'Read') -or ($SaveProject -ne '' -and $permission.name -eq 'Write') -or ($ProjectLeader -ne '' -and $permission.name -eq 'ProjectLeader'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
#                    $permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/permissions/users/$userID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
            }
     } 
   }

   # Set New Group / User Permissions

   $ProjectCapabilities = ""
   If ($ViewProject -eq 'Allow' -or $ViewProject -eq 'Deny'){$ProjectCapabilities += '        <capability name="Read" mode="' + $ViewProject +'" />'}
   If ($SaveProject -eq 'Allow' -or $SaveProject -eq 'Deny'){$ProjectCapabilities += '        <capability name="Write" mode="' + $SaveProject +'" />'}
   If ($ProjectLeader -eq 'Allow' -or $ProjectLeader -eq 'Deny'){$ProjectCapabilities += '        <capability name="ProjectLeader" mode="' + $ProjectLeader +'" />'}

#   $projectCapabilities
   $Project_Request = '
        <tsRequest>
          <permissions>
            <granteeCapabilities>'     + $affectedObject + '
              <capabilities>' + $ProjectCapabilities + '
              </capabilities>
            </granteeCapabilities>
          </permissions>
        </tsRequest>
        '

 #  $Project_Request

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/permissions -Headers $headers -Method PUT -Body $Project_request
   #$response.tsResponse

  # Check existing Workbook Permissions

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/workbooks -Headers $headers -Method Get

  foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
   { 
    if ($groupID -ne '' -and $groupID -eq $detail.group.id)
     {
       # Group is already permissioned against Project

      #"GroupID " + $GroupID
 
       # Check existing permissions
 
        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewWorkbook -ne '' -and $permission.name -eq 'Read') -or ($DownloadImagePDF -ne '' -and $permission.name -eq 'ExportImage') -or ($DownloadSummaryData -ne '' -and $permission.name -eq 'ExportData') -or ($ViewComments -ne '' -and $permission.name -eq 'ViewComments') -or ($AddComments -ne '' -and $permission.name -eq 'AddComment') -or ($Filter -ne '' -and $permission.name -eq 'Filter') -or ($DownloadFullData -ne '' -and $permission.name -eq 'ViewUnderlyingData') -or ($ShareCustomized -ne '' -and $permission.name -eq 'ShareView') -or ($WebEdit -ne '' -and $permission.name -eq 'WebAuthoring') -or ($SaveWorkbook -ne '' -and $permission.name -eq 'Write') -or ($MoveWorkbook -ne '' -and $permission.name -eq 'ChangeHierarchy') -or ($DeleteWorkbook -ne '' -and $permission.name -eq 'Delete') -or ($DownloadWorkbook -ne '' -and $permission.name -eq 'ExportXML') -or ($SetWorkbookPermissions -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/workbooks/groups/$groupID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
           }
     } 

    if ($UserID -ne '' -and $UserID -eq $detail.user.id)
     {
       # User is already permissioned against Project

      #"UserID " + $UserID

        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewWorkbook -ne '' -and $permission.name -eq 'Read') -or ($DownloadImagePDF -ne '' -and $permission.name -eq 'ExportImage') -or ($DownloadSummaryData -ne '' -and $permission.name -eq 'ExportData') -or ($ViewComments -ne '' -and $permission.name -eq 'ViewComments') -or ($AddComments -ne '' -and $permission.name -eq 'AddComment') -or ($Filter -ne '' -and $permission.name -eq 'Filter') -or ($DownloadFullData -ne '' -and $permission.name -eq 'ViewUnderlyingData') -or ($ShareCustomized -ne '' -and $permission.name -eq 'ShareView') -or ($WebEdit -ne '' -and $permission.name -eq 'WebAuthoring') -or ($SaveWorkbook -ne '' -and $permission.name -eq 'Write') -or ($MoveWorkbook -ne '' -and $permission.name -eq 'ChangeHierarchy') -or ($DeleteWorkbook -ne '' -and $permission.name -eq 'Delete') -or ($DownloadWorkbook -ne '' -and $permission.name -eq 'ExportXML') -or ($SetWorkbookPermissions -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    #$permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/workbooks/users/$userID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
            }
     } 
   }
   
   $WorkbookCapabilities = ""
   If ($ViewWorkbook -eq 'Allow' -or $ViewWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Read" mode="' + $ViewWorkbook +'" />'}
   If ($SaveWorkbook -eq 'Allow' -or $SaveWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Write" mode="' + $SaveWorkbook +'" />'}
   If ($DownloadImagePDF -eq 'Allow' -or $DownloadImagePDF -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportImage" mode="' + $DownloadImagePDF +'" />'}
   If ($DownloadSummaryData -eq 'Allow' -or $DownloadSummaryData -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportData" mode="' + $DownloadSummaryData +'" />'}
   If ($ViewComments -eq 'Allow' -or $ViewComments -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ViewComments" mode="' + $ViewComments +'" />'}
   If ($AddComments -eq 'Allow' -or $AddComments -eq 'Deny'){$WorkbookCapabilities += '        <capability name="AddComment" mode="' + $AddComments +'" />'}
   If ($Filter -eq 'Allow' -or $Filter -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Filter" mode="' + $Filter +'" />'}
   If ($DownloadFullData -eq 'Allow' -or $DownloadFullData -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ViewUnderlyingData" mode="' + $DownloadFullData +'" />'}
   If ($ShareCustomized -eq 'Allow' -or $ShareCustomized -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ShareView" mode="' + $ShareCustomized +'" />'}
   If ($WebEdit -eq 'Allow' -or $WebEdit -eq 'Deny'){$WorkbookCapabilities += '        <capability name="WebAuthoring" mode="' + $WebEdit +'" />'}
   If ($MoveWorkbook -eq 'Allow' -or $MoveWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ChangeHierarchy" mode="' + $MoveWorkbook +'" />'}
   If ($DeleteWorkbook -eq 'Allow' -or $DeleteWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Delete" mode="' + $DeleteWorkbook +'" />'}
   If ($DownloadWorkbook -eq 'Allow' -or $DownloadWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportXML" mode="' + $DownloadWorkbook +'" />'}
   If ($SetWorkbookPermissions -eq 'Allow' -or $SetWorkbookPermissions -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ChangePermissions" mode="' + $SetWorkbookPermissions +'" />'}

   $Workbook_request = '
        <tsRequest>
          <permissions>
            <granteeCapabilities>'     + $affectedObject + '
              <capabilities>' + $WorkbookCapabilities + '
              </capabilities>
            </granteeCapabilities>
          </permissions>
        </tsRequest>
        '

#   $Workbook_request

 if ($WorkbookCapabilities -ne '')
  {  
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/workbooks -Headers $headers -Method PUT -Body $Workbook_request
   #$response.tsResponse
  }


  # Check existing DataSource Permissions

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/datasources -Headers $headers -Method Get

  foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
   { 
    if ($groupID -ne '' -and $groupID -eq $detail.group.id)
     {
       # Group is already permissioned against Project

      #"GroupID " + $GroupID
 
       # Check existing permissions
 
        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewDataSource  -ne '' -and $permission.name -eq 'Read') -or ($Connect -ne '' -and $permission.name -eq 'Connect') -or ($SaveDataSource  -ne '' -and $permission.name -eq 'Write') -or ($DownloadDataSource  -ne '' -and $permission.name -eq 'ExportXML') -or ($DeleteDataSource  -ne '' -and $permission.name -eq 'Delete') -or ($SetDataSourcePermissions  -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/datasources/groups/$groupID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
           }
     } 

    if ($UserID -ne '' -and $UserID -eq $detail.user.id)
     {
       # User is already permissioned against Project

      #"UserID " + $UserID

        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewDataSource  -ne '' -and $permission.name -eq 'Read') -or ($Connect -ne '' -and $permission.name -eq 'Connect') -or ($SaveDataSource  -ne '' -and $permission.name -eq 'Write') -or ($DownloadDataSource  -ne '' -and $permission.name -eq 'ExportXML') -or ($DeleteDataSource  -ne '' -and $permission.name -eq 'Delete') -or ($SetDataSourcePermissions  -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
 #                   $permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/datasources/users/$userID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
            }
     } 
   }
   
   $DataSourceCapabilities = ""
   If ($ViewDataSource -eq 'Allow' -or $ViewDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Read" mode="' + $ViewDataSource +'" />'}
   If ($Connect  -eq 'Allow' -or $Connect  -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Connect" mode="' + $Connect  +'" />'}
   If ($SaveDataSource  -eq 'Allow' -or $SaveDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Write" mode="' + $SaveDataSource +'" />'}
   If ($DownloadDataSource  -eq 'Allow' -or $DownloadDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="ExportXML" mode="' + $DownloadDataSource +'" />'}
   If ($DeleteDataSource  -eq 'Allow' -or $DeleteDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Delete" mode="' + $DeleteDataSource +'" />'}
   If ($SetDataSourcePermissions  -eq 'Allow' -or $SetDataSourcePermissions -eq 'Deny'){$DataSourceCapabilities += '        <capability name="ChangePermissions" mode="' + $SetDataSourcePermissions +'" />'}

   $DataSource_request = '
        <tsRequest>
          <permissions>
            <granteeCapabilities>'     + $affectedObject + '
              <capabilities>' + $DataSourceCapabilities + '
              </capabilities>
            </granteeCapabilities>
          </permissions>
        </tsRequest>
        '

#   $DataSource_request

 if ($DataSourceCapabilities -ne '')
  {  
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/projects/$ProjectID/default-permissions/datasources -Headers $headers -Method PUT -Body $DataSource_request
   #$response.tsResponse
  }

  "Project Permissions updated."
 }
 catch {"Unable to update Project Permissions." + " :- " + $_.Exception.Message}
}

function TS-UpdateWorkbookPermissions
{
param(
  [string[]] $ProjectName = "",
  [string[]] $workbookName = "",
  [string[]] $GroupName = "",
  [string[]] $Domain = "local",
  [string[]] $UserAccount = "",

  #Workbook Permissions
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadImagePDF = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadSummaryData = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewComments = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $AddComments = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $Filter = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadFullData = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ShareCustomized = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $WebEdit = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SaveWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $MoveWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DeleteWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadWorkbook = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SetWorkbookPermissions = "",
  [string[]] $WorkbookID = "",
  [string[]] $UserID,
  [string[]] $GroupID


 )

try
 {

    if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}

  if ($GroupName -ne '')
   {
    $GroupID = TS-GetGroupDetails -name $GroupName -Domain $Domain
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $UserID = ''
   }
  if ($GroupID -ne '')
   {
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $UserID = ''
   }

  if ($UserAccount -ne '')
   {
    $UserID = TS-GetUserDetails -name $UserAccount
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupID = ''
   }

  if ($UserID -ne '')
   {
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupID = ''
   }

  # Check existing Workbook Permissions

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/permissions -Headers $headers -Method Get

  foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
   { 
    if ($groupID -ne '' -and $groupID -eq $detail.group.id)
     {
       # Group is already permissioned against Project

      #"GroupID " + $GroupID
 
       # Check existing permissions
 
        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewWorkbook -ne '' -and $permission.name -eq 'Read') -or ($DownloadImagePDF -ne '' -and $permission.name -eq 'ExportImage') -or ($DownloadSummaryData -ne '' -and $permission.name -eq 'ExportData') -or ($ViewComments -ne '' -and $permission.name -eq 'ViewComments') -or ($AddComments -ne '' -and $permission.name -eq 'AddComment') -or ($Filter -ne '' -and $permission.name -eq 'Filter') -or ($DownloadFullData -ne '' -and $permission.name -eq 'ViewUnderlyingData') -or ($ShareCustomized -ne '' -and $permission.name -eq 'ShareView') -or ($WebEdit -ne '' -and $permission.name -eq 'WebAuthoring') -or ($SaveWorkbook -ne '' -and $permission.name -eq 'Write') -or ($MoveWorkbook -ne '' -and $permission.name -eq 'ChangeHierarchy') -or ($DeleteWorkbook -ne '' -and $permission.name -eq 'Delete') -or ($DownloadWorkbook -ne '' -and $permission.name -eq 'ExportXML') -or ($SetWorkbookPermissions -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                  $permission_name
                    $GroupID
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    $permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/permissions/groups/$groupID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
           }
     } 


    if ($UserID -ne '' -and $UserID -eq $detail.user.id)
     {
       # User is already permissioned against Project

      #"UserID " + $UserID

        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewWorkbook -ne '' -and $permission.name -eq 'Read') -or ($DownloadImagePDF -ne '' -and $permission.name -eq 'ExportImage') -or ($DownloadSummaryData -ne '' -and $permission.name -eq 'ExportData') -or ($ViewComments -ne '' -and $permission.name -eq 'ViewComments') -or ($AddComments -ne '' -and $permission.name -eq 'AddComment') -or ($Filter -ne '' -and $permission.name -eq 'Filter') -or ($DownloadFullData -ne '' -and $permission.name -eq 'ViewUnderlyingData') -or ($ShareCustomized -ne '' -and $permission.name -eq 'ShareView') -or ($WebEdit -ne '' -and $permission.name -eq 'WebAuthoring') -or ($SaveWorkbook -ne '' -and $permission.name -eq 'Write') -or ($MoveWorkbook -ne '' -and $permission.name -eq 'ChangeHierarchy') -or ($DeleteWorkbook -ne '' -and $permission.name -eq 'Delete') -or ($DownloadWorkbook -ne '' -and $permission.name -eq 'ExportXML') -or ($SetWorkbookPermissions -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    #$permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/permissions/users/$userID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
            }
     } 
   }
   
   $WorkbookCapabilities = ""
   If ($ViewWorkbook -eq 'Allow' -or $ViewWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Read" mode="' + $ViewWorkbook +'" />'}
   If ($SaveWorkbook -eq 'Allow' -or $SaveWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Write" mode="' + $SaveWorkbook +'" />'}
   If ($DownloadImagePDF -eq 'Allow' -or $DownloadImagePDF -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportImage" mode="' + $DownloadImagePDF +'" />'}
   If ($DownloadSummaryData -eq 'Allow' -or $DownloadSummaryData -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportData" mode="' + $DownloadSummaryData +'" />'}
   If ($ViewComments -eq 'Allow' -or $ViewComments -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ViewComments" mode="' + $ViewComments +'" />'}
   If ($AddComments -eq 'Allow' -or $AddComments -eq 'Deny'){$WorkbookCapabilities += '        <capability name="AddComment" mode="' + $AddComments +'" />'}
   If ($Filter -eq 'Allow' -or $Filter -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Filter" mode="' + $Filter +'" />'}
   If ($DownloadFullData -eq 'Allow' -or $DownloadFullData -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ViewUnderlyingData" mode="' + $DownloadFullData +'" />'}
   If ($ShareCustomized -eq 'Allow' -or $ShareCustomized -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ShareView" mode="' + $ShareCustomized +'" />'}
   If ($WebEdit -eq 'Allow' -or $WebEdit -eq 'Deny'){$WorkbookCapabilities += '        <capability name="WebAuthoring" mode="' + $WebEdit +'" />'}
   If ($MoveWorkbook -eq 'Allow' -or $MoveWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ChangeHierarchy" mode="' + $MoveWorkbook +'" />'}
   If ($DeleteWorkbook -eq 'Allow' -or $DeleteWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Delete" mode="' + $DeleteWorkbook +'" />'}
   If ($DownloadWorkbook -eq 'Allow' -or $DownloadWorkbook -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportXML" mode="' + $DownloadWorkbook +'" />'}
   If ($SetWorkbookPermissions -eq 'Allow' -or $SetWorkbookPermissions -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ChangePermissions" mode="' + $SetWorkbookPermissions +'" />'}

   $Workbook_request = '
        <tsRequest>
          <permissions>
            <granteeCapabilities>'     + $affectedObject + '
              <capabilities>' + $WorkbookCapabilities + '
              </capabilities>
            </granteeCapabilities>
          </permissions>
        </tsRequest>
        '

#   $Workbook_request

 if ($WorkbookCapabilities -ne '')
  {  
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/permissions -Headers $headers -Method PUT -Body $Workbook_request
   #$response.tsResponse
  }


  "Workbook Permissions updated."
 }
 catch {"Unable to update Workbook Permissions. :- " + $_.Exception.Message}
}

function TS-UpdateViewPermissions
{
param(
  [string[]] $ProjectName = "",
  [string[]] $workbookName = "",
  [string[]] $ViewName = "",
  [string[]] $GroupName = "",
  [string[]] $Domain = "local",
  [string[]] $UserAccount = "",

  #Workbook Permissions
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewView = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadImagePDF = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadSummaryData = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewComments = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $AddComments = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $Filter = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadFullData = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ShareCustomized = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $WebEdit = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DeleteView = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SetViewPermissions = "",
  [string[]] $ViewID = "",
  [string[]] $UserID,
  [string[]] $GroupID


 )

try
 {
  if ($ViewID -ne '') {$ViewID} else {$ViewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName}

  if ($GroupName -ne '')
   {
    $GroupID = TS-GetGroupDetails -name $GroupName -Domain $Domain
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $UserID = ''
   }
  if ($GroupID -ne '')
   {
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $UserID = ''
   }

  if ($UserAccount -ne '')
   {
    $UserID = TS-GetUserDetails -name $UserAccount
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupID = ''
   }

  if ($UserID -ne '')
   {
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupID = ''
   }

  # Check existing Workbook Permissions

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views/$ViewID/permissions -Headers $headers -Method Get

  foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
   { 
    if ($groupID -ne '' -and $groupID -eq $detail.group.id)
     {
       # Group is already permissioned against Project

      #"GroupID " + $GroupID
 
       # Check existing permissions
 
        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewView -ne '' -and $permission.name -eq 'Read') -or ($DownloadImagePDF -ne '' -and $permission.name -eq 'ExportImage') -or ($DownloadSummaryData -ne '' -and $permission.name -eq 'ExportData') -or ($ViewComments -ne '' -and $permission.name -eq 'ViewComments') -or ($AddComments -ne '' -and $permission.name -eq 'AddComment') -or ($Filter -ne '' -and $permission.name -eq 'Filter') -or ($DownloadFullData -ne '' -and $permission.name -eq 'ViewUnderlyingData') -or ($ShareCustomized -ne '' -and $permission.name -eq 'ShareView') -or ($WebEdit -ne '' -and $permission.name -eq 'WebAuthoring') -or ($DeleteView -ne '' -and $permission.name -eq 'Delete')  -or ($SetViewPermissions -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                  $permission_name
                    $GroupID
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    $permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views/$ViewID/permissions/groups/$groupID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
           }
     } 


    if ($UserID -ne '' -and $UserID -eq $detail.user.id)
     {
       # User is already permissioned against Project

      #"UserID " + $UserID

        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewView -ne '' -and $permission.name -eq 'Read') -or ($DownloadImagePDF -ne '' -and $permission.name -eq 'ExportImage') -or ($DownloadSummaryData -ne '' -and $permission.name -eq 'ExportData') -or ($ViewComments -ne '' -and $permission.name -eq 'ViewComments') -or ($AddComments -ne '' -and $permission.name -eq 'AddComment') -or ($Filter -ne '' -and $permission.name -eq 'Filter') -or ($DownloadFullData -ne '' -and $permission.name -eq 'ViewUnderlyingData') -or ($ShareCustomized -ne '' -and $permission.name -eq 'ShareView') -or ($WebEdit -ne '' -and $permission.name -eq 'WebAuthoring') -or ($DeleteView -ne '' -and $permission.name -eq 'Delete')  -or ($SetViewPermissions -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    #$permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views/$ViewID/permissions/users/$userID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
            }
     } 
   }
   
   $WorkbookCapabilities = ""
   If ($ViewView -eq 'Allow' -or $ViewView -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Read" mode="' + $ViewView +'" />'}
   If ($DownloadImagePDF -eq 'Allow' -or $DownloadImagePDF -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportImage" mode="' + $DownloadImagePDF +'" />'}
   If ($DownloadSummaryData -eq 'Allow' -or $DownloadSummaryData -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ExportData" mode="' + $DownloadSummaryData +'" />'}
   If ($ViewComments -eq 'Allow' -or $ViewComments -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ViewComments" mode="' + $ViewComments +'" />'}
   If ($AddComments -eq 'Allow' -or $AddComments -eq 'Deny'){$WorkbookCapabilities += '        <capability name="AddComment" mode="' + $AddComments +'" />'}
   If ($Filter -eq 'Allow' -or $Filter -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Filter" mode="' + $Filter +'" />'}
   If ($DownloadFullData -eq 'Allow' -or $DownloadFullData -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ViewUnderlyingData" mode="' + $DownloadFullData +'" />'}
   If ($ShareCustomized -eq 'Allow' -or $ShareCustomized -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ShareView" mode="' + $ShareCustomized +'" />'}
   If ($WebEdit -eq 'Allow' -or $WebEdit -eq 'Deny'){$WorkbookCapabilities += '        <capability name="WebAuthoring" mode="' + $WebEdit +'" />'}
   If ($DeleteView -eq 'Allow' -or $DeleteView -eq 'Deny'){$WorkbookCapabilities += '        <capability name="Delete" mode="' + $DeleteView +'" />'}
   If ($SetViewPermissions -eq 'Allow' -or $SetViewPermissions -eq 'Deny'){$WorkbookCapabilities += '        <capability name="ChangePermissions" mode="' + $SetViewPermissions +'" />'}

   $Workbook_request = '
        <tsRequest>
          <permissions>
            <granteeCapabilities>'     + $affectedObject + '
              <capabilities>' + $WorkbookCapabilities + '
              </capabilities>
            </granteeCapabilities>
          </permissions>
        </tsRequest>
        '
 if ($WorkbookCapabilities -ne '')
  {  
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views/$ViewID/permissions -Headers $headers -Method PUT -Body $Workbook_request
   $response.tsResponse
  }


  "View Permissions updated."
 }
 catch {"Unable to update View Permissions. :- " + $_.Exception.Message}
}


function TS-UpdateDataSourcePermissions
{
param(
  [string[]] $ProjectName = "",
  [string[]] $DataSourceName = "",
  [string[]] $GroupName = "",
  [string[]] $Domain ="local",
  [string[]] $UserAccount = "",

  #DataSource Permissions
  [validateset('Allow', 'Deny', 'Blank')][string[]] $ViewDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $Connect = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SaveDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DownloadDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $DeleteDataSource = "",
  [validateset('Allow', 'Deny', 'Blank')][string[]] $SetDataSourcePermissions = "",
  [string[]] $DataSourceID = "",
  [string[]] $UserID,
  [string[]] $GroupID
 )

try
 {

  $GroupID = ''

  if ($DataSourceID -ne ''){ $DataSourceID}else{ $DataSourceID = TS-getDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}

  if ($GroupName -ne '')
   {
    $GroupID = TS-GetGroupDetails -name $GroupName -Domain $Domain
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $userID = ''
   }
  if ($GroupID -ne '')
   {
    $affectedObject = '      <group id="' + $GroupID +'" />'
    $userID = ''
   }

  if ($UserAccount -ne '')
   {
    $UserID = TS-GetUserDetails -name $UserAccount
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupID = ''
   }

  if ($UserID -ne '')
   {
    $affectedObject = '      <user id="' + $UserID +'" />'
    $GroupID = ''
   }
   $UserID
   $DataSourceID
   $GroupID

  # Check existing DataSource Permissions

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/permissions -Headers $headers -Method Get

  foreach ($detail in $response.tsResponse.permissions.granteeCapabilities)
   { 
    if ($groupID -ne '' -and $groupID -eq $detail.group.id)
     {
       # Group is already permissioned against DataSource

      #"GroupID " + $GroupID
 
       # Check existing permissions
 
        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewDataSource  -ne '' -and $permission.name -eq 'Read') -or ($Connect -ne '' -and $permission.name -eq 'Connect') -or ($SaveDataSource  -ne '' -and $permission.name -eq 'Write') -or ($DownloadDataSource  -ne '' -and $permission.name -eq 'ExportXML') -or ($DeleteDataSource  -ne '' -and $permission.name -eq 'Delete') -or ($SetDataSourcePermissions  -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                  $permission_name
                    $GroupID
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    $permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/permissions/groups/$groupID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
           }
     } 


    if ($UserID -ne '' -and $UserID -eq $detail.user.id)
     {
       # User is already permissioned against DataSource

      #"UserID " + $UserID

        ForEach ($permission in $detail.capabilities.capability)
           {
             if (($ViewDataSource  -ne '' -and $permission.name -eq 'Read') -or ($Connect -ne '' -and $permission.name -eq 'Connect') -or ($SaveDataSource  -ne '' -and $permission.name -eq 'Write') -or ($DownloadDataSource  -ne '' -and $permission.name -eq 'ExportXML') -or ($DeleteDataSource  -ne '' -and $permission.name -eq 'Delete') -or ($SetDataSourcePermissions  -ne '' -and $permission.name -eq 'ChangePermissions'))
                 {
                    $permission_name = $permission.name
                    $permission_mode = $permission.mode
                    #$permission_name, $permission_mode
                    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/permissions/users/$userID/$permission_name/$permission_mode -Headers $headers -Method Delete
                 }
            }
     } 
   }
   
   $DataSourceCapabilities = ""
   If ($ViewDataSource -eq 'Allow' -or $ViewDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Read" mode="' + $ViewDataSource +'" />'}
   If ($Connect  -eq 'Allow' -or $Connect  -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Connect" mode="' + $Connect  +'" />'}
   If ($SaveDataSource  -eq 'Allow' -or $SaveDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Write" mode="' + $SaveDataSource +'" />'}
   If ($DownloadDataSource  -eq 'Allow' -or $DownloadDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="ExportXML" mode="' + $DownloadDataSource +'" />'}
   If ($DeleteDataSource  -eq 'Allow' -or $DeleteDataSource -eq 'Deny'){$DataSourceCapabilities += '        <capability name="Delete" mode="' + $DeleteDataSource +'" />'}
   If ($SetDataSourcePermissions  -eq 'Allow' -or $SetDataSourcePermissions -eq 'Deny'){$DataSourceCapabilities += '        <capability name="ChangePermissions" mode="' + $SetDataSourcePermissions +'" />'}

   $DataSource_request = '
        <tsRequest>
          <permissions>
            <granteeCapabilities>'     + $affectedObject + '
              <capabilities>' + $DataSourceCapabilities + '
              </capabilities>
            </granteeCapabilities>
          </permissions>
        </tsRequest>
        '
        $DataSource_request
 if ($DataSourceCapabilities -ne '')
  {  
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/permissions -Headers $headers -Method PUT -Body $DataSource_request
   #$response.tsResponse
  }


  "DataSource Permissions updated."
 }
 catch {"Unable to update DataSource Permissions. :- " + $_.Exception.Message}
}



###### Jobs, Tasks, and Schedules


function TS-QuerySchedules
{
 try
 { 
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   {
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/schedules?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1
    $response.tsResponse.schedules.schedule
   }
  
 }
 catch{"Unable to Query Schedules :- " + $_.Exception.Message}
}


function TS-UpdateSchedule
{
param(
 [string[]] $ScheduleName = "",
 [string[]] $newScheduleName ="",
 [string[]] $newPriority ="",
 [validateset('Active','Suspended')][string[]] $newState = "",
 [validateset('Parallel', 'Serial')][string[]] $newExecutionOrder = "",
 [validateset('Hourly', 'Daily', 'Weekly', 'Monthly')][string[]] $newFrequency ="",
 [string[]] $newStartTime ="00:00",
 [string[]] $newEndTime ="00:00",
 [string[]] $newInterval = ""
 )

try
 {
  $ID = TS-GetScheduleDetails -name $ScheduleName
  $ID


  $updated_schedule = ""
  $updated_frequency = ""
  $updated_intervals = ""

  if ($NewScheduleName -ne '') {$updated_schedule += ' name="'+ $newScheduleName+'"'}
  if ($newPriority -ne '') {$updated_schedule += ' priority="'+ $newPriority+'"'}
  if ($newExecutionOrder -ne '') {$updated_schedule += ' executionOrder="'+ $newExecutionOrder+'"'}
  if ($newState -ne '') {$updated_schedule += ' state="'+ $newState+'"'}
  if ($newFrequency -ne '') 
    {
     
     if ($newFrequency -eq 'Hourly')
      {     
        If ($newInterval -eq '15' -or $newInterval -eq '30')
         {
           $interval_text = '<interval minutes="'+$newInterval +'" />'
         }
        else
         {
           $interval_text = '<interval hours="'+$newInterval +'" />'
         }
        $updated_schedule += ' frequency="'+ $newFrequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $newStartTime+':00" end="' +$newEndTime +':00">
         <intervals>
         ' + $interval_text + '
          </intervals>
      </frequencyDetails>'
      }
      elseif
       ($newFrequency -eq 'Daily')
      {     
        $updated_schedule += ' frequency="'+ $newFrequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $newStartTime+':00">
         <intervals>
          <interval hours="1" />
        </intervals>
      </frequencyDetails>'
      }
      elseif
       ($newFrequency -eq 'Weekly')
      {     
        $IntervalsArrary = $newInterval.Split(",")
        Foreach ($Interval in $IntervalsArrary) {$interval_text += '<interval weekDay ="'+ $Interval +'" />'}


        $updated_schedule += ' frequency="'+ $newFrequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $newStartTime+':00">
         <intervals>
          ' + $interval_text + '
        </intervals>
      </frequencyDetails>'
      }
      elseif
       ($newFrequency -eq 'Monthly')
      {     
        $updated_schedule += ' frequency="'+ $newFrequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $newStartTime+':00">
         <intervals>
          <interval monthDay="'+$newInterval +'" />
        </intervals>
      </frequencyDetails>'
      }
    }

   $Schedule_request = "
        <tsRequest>
          <schedule 
          " + $updated_schedule +">" + $updated_frequency + $updated_intervals + "
          </schedule>
        </tsRequest>
        "

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/schedules/$ID -Headers $headers -Method PUT -Body $Schedule_request
  

   ForEach ($detail in $response.tsresponse.schedule)
    { 
       $Schedule = [pscustomobject]@{
         Name=$detail.name;
         Type=$detail.type;
         Priority=$detail.priority; 
         CreatedAt=$detail.CreatedAt; 
         UpdatedAt=$detail.updatedAt; 
         Frequency=$detail.frequency; 
         NextRunAt=$detail.nextrunAt; 
         ExecutionOrder=$detail.executionOrder; 
         State=$detail.state
         FrequencyStart=$detail.frequencyDetails.start
         FrequencyEnd=$detail.frequencyDetails.end
         Weekdays=$detail.frequencyDetails.intervals.interval.weekday
         Hour=$detail.frequencyDetails.intervals.interval.hours


       }
       $Schedule
     }



   
 }
 catch{"Unable to Update Schedule. " + $ScheduleName+ " :- " + $_.Exception.Message}
}

function TS-DeleteSchedule
{
param(
 [string[]] $ScheduleName = ""
 )

try
 {
  $ID = TS-GetScheduleDetails -name $ScheduleName
  $ID
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/schedules/$ID -Headers $headers -Method DELETE
 }
 catch{"Unable to Delete Schedule. " + $ScheduleName + " :- " + $_.Exception.Message}
}




function TS-CreateSchedule
{
param(
 [string[]] $ScheduleName = "",
 [string[]] $Priority ="",
 [validateset('Extract','Subscription')][string[]] $Type = "",
 [validateset('Active','Suspended')][string[]] $State = "",
 [validateset('Parallel', 'Serial')][string[]] $ExecutionOrder = "Parallel",
 [validateset('Hourly', 'Daily', 'Weekly', 'Monthly')][string[]] $Frequency ="",
 [string[]] $StartTime ="00:00",
 [string[]] $EndTime ="00:00",
 [string[]] $Interval = ""
 )

try
 {
  $updated_schedule = ""
  $updated_frequency = ""
  $updated_intervals = ""

  if ($ScheduleName -ne '') {$updated_schedule += ' name="'+ $ScheduleName+'"'}
  if ($Priority -ne '') {$updated_schedule += ' priority="'+ $Priority+'"'}
  if ($ExecutionOrder -ne '') {$updated_schedule += ' executionOrder="'+ $ExecutionOrder+'"'}
  if ($State -ne '') {$updated_schedule += ' state="'+ $State+'"'}
  if ($Type -ne '') {$updated_schedule += ' type="'+ $Type+'"'}

  if ($Frequency -ne '') 
    {
     
     if ($Frequency -eq 'Hourly')
      {     
        If ($Interval -eq '15' -or $Interval -eq '30')
         {
           $interval_text = '<interval minutes="'+$Interval +'" />'
         }
        else
         {
           $interval_text = '<interval hours="'+$Interval +'" />'
         }
        $updated_schedule += ' frequency="'+ $Frequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $StartTime+':00" end="' +$EndTime +':00">
         <intervals>
         ' + $interval_text + '
          </intervals>
      </frequencyDetails>'
      }
      elseif
       ($Frequency -eq 'Daily')
      {     
        $updated_schedule += ' frequency="'+ $Frequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $StartTime+':00">
         <intervals>
          <interval hours="1" />
        </intervals>
      </frequencyDetails>'
      }
      elseif
       ($Frequency -eq 'Weekly')
      {     
        $IntervalsArrary = $Interval.Split(",")
        Foreach ($Interval in $IntervalsArrary) {$interval_text += '<interval weekDay ="'+ $Interval +'" />'}


        $updated_schedule += ' frequency="'+ $Frequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $StartTime+':00">
         <intervals>
          ' + $interval_text + '
        </intervals>
      </frequencyDetails>'
      }
      elseif
       ($Frequency -eq 'Monthly')
      {     
        $updated_schedule += ' frequency="'+ $Frequency+'"'
        $updated_frequency = '<frequencyDetails start="'+ $StartTime+':00">
         <intervals>
          <interval monthDay="'+$Interval +'" />
        </intervals>
      </frequencyDetails>'
      }
    }

   $Schedule_request = "
        <tsRequest>
          <schedule 
          " + $updated_schedule +">" + $updated_frequency + $updated_intervals + "
          </schedule>
        </tsRequest>
        "

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/schedules -Headers $headers -Method POST -Body $Schedule_request
   $response.tsresponse.schedule
   
 }
 catch{"Unable to Create Schedule. " +$ScheduleName + " :- " + $_.Exception.Message }
}


function TS-QueryExtractRefreshTasksForSchedule
{
 param(
 [string[]] $ScheduleName = ""
 )

 try
 {
  $ID = TS-GetScheduleDetails -name $ScheduleName
  $ID
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   {
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/schedules/$ID/extracts?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.extracts.extract)
     { 
       $datasource_name = TS-GetDataSourceDetails -ID $detail.datasource.id
       $workbook_name = TS-GetWorkbookDetails -ID $detail.workbook.id
       $Task = [pscustomobject]@{Priority=$detail.priority; Type=$detail.Type; Workbook=$workbook_name; Datasource=$datasource_name; ID=$detail.ID}
       $Task
     }
   }
 }
 catch{"Unable to Query Extract Refresh Tasks. " + $ScheduleName + " :- " + $_.Exception.Message }
}


function TS-GetScheduleDetails
{
 param(
 [string[]] $Name = "",
 [string[]] $ID = ""
 )
 
$PageSize = 100
$PageNumber = 1
$done = 'FALSE'

While ($done -eq 'FALSE')
 {
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/schedules?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

  $totalAvailable = $response.tsResponse.pagination.totalAvailable

  If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

  $PageNumber += 1

  foreach ($detail in $response.tsResponse.schedules.schedule)
   { 
    if ($Name -eq $detail.name){Return $detail.ID}
    if ($ID -eq $detail.ID){Return $detail.Name}
   }
 }
 
}

function TS-RunExtractRefreshTask
{
 param(
[string[]] $ScheduleName ="",
[string[]] $WorkbookName ="",
[string[]] $DataSourceName ="",
[string[]] $ProjectName ="",
[string[]] $TaskID =""
  )
  try
  {

     if ($TaskID -ne ''){} else {$TaskID = TS-GetExtractRefreshTaskID -ScheduleName $ScheduleName -WorkbookName $WorkbookName -DataSourceName $DataSourceName -ProjectName $ProjectName}
     $body = "<tsRequest></tsRequest>"
   
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/tasks/extractRefreshes/$TaskID/runNow -Headers $headers -Method POST -Body $body -ContentType "text/xml"
     $response.tsresponse.job
  }
 catch{"Unable to Run Extract Refresh Task. :- " + $_.Exception.Message }
}


function TS-GetExtractRefreshTaskID
{
param(
[string[]] $ScheduleName ="",
[string[]] $WorkbookName ="",
[string[]] $DataSourceName ="",
[string[]] $ProjectName =""
)
  $DataSourceID = ""
  $WorkbookID = ""

  if ($DataSourceName -ne '') {$DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
  if ($WorkbookName -ne ''){$workbookID = TS-GetWorkbookDetails -Name $WorkBookName -ProjectName $ProjectName}

  $Tasks = TS-GetExtractRefreshTasks

  ForEach ($Task in $Tasks)
    {
      If ($ScheduleName -eq $Task.Schedule -and ($DataSourceID -eq $Task.datasourceID -or $workbookID -eq $task.WorkbookID))
       {
         return $Task.TaskID
       }
    }
}

function TS-GetExtractRefreshTasks
{
 try
  {

  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   {
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/tasks/extractRefreshes?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.tasks.task.extractRefresh)
     { 
       $datasource_name = TS-GetDataSourceDetails -ID $detail.datasource.id
       $workbook_name = TS-GetWorkbookDetails -ID $detail.workbook.id
       $Tasks = [pscustomobject]@{Type=$detail.type; Priority=$detail.priority; Schedule=$detail.schedule.name; DatasourceName=$datasource_name; WorkbookName = $workbook_name; ConsecutiveFailedCount = $detail.consecutiveFailedCount; TaskID = $detail.id; DataSourceID = $detail.datasource.id; WorkbookID = $detail.workbook.id}
       $Tasks
     }
   }
 }
 catch {"Unable to Get Extract Refresh Tasks"}

}

function TS-GetExtractRefreshTask
{

 param(
[string[]] $ScheduleName ="",
[string[]] $WorkbookName ="",
[string[]] $DataSourceName ="",
[string[]] $ProjectName ="",
[string[]] $TaskID =""
  )
  try
  {
     if ($TaskID -ne ''){} else {$TaskID = TS-GetExtractRefreshTaskID -ScheduleName $ScheduleName -WorkbookName $WorkbookName -DataSourceName $DataSourceName -ProjectName $ProjectName}
    $TaskID


   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/tasks/extractRefreshes/$TaskID -Headers $headers -Method GET
   $response.tsresponse.task

   # ForEach ($detail in $response.tsResponse.tasks.task.extractRefresh)
    # { 
     #  $datasource_name = TS-GetDataSourceDetails -ID $detail.datasource.id
      # $workbook_name = TS-GetWorkbookDetails -ID $detail.workbook.id
       #$Tasks = [pscustomobject]@{Type=$detail.type; Priority=$detail.priority; Schedule=$detail.schedule.name; DatasourceName=$datasource_name; WorkbookName = $workbook_name; ConsecutiveFailedCount = $detail.consecutiveFailedCount; TaskID = $detail.id; DataSourceID = $detail.datasource.id; WorkbookID = $detail.workbook.id}
       #$Tasks
     #}
   #}
 }
 catch {"Unable to Get Extract Refresh Tasks"}

}






function TS-AddDataSourceToSchedule
{
param(
[string[]] $ScheduleName ="",
[string[]] $DataSourceName ="",
[string[]] $ProjectName ="",
[string[]] $ScheduleID ="",
[string[]] $DataSourceID =""
)
try
 {
  if ($DataSourceID -ne ''){} else{$DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
  if ($ScheduleID -ne ''){} else{$ScheduleID = TS-GetScheduleDetails -name $ScheduleName}

  $body = '<tsRequest>
    <task>
    <extractRefresh>
      <datasource id="'+$DataSourceID + '" />
    </extractRefresh>
    </task>
  </tsRequest>'

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/schedules/$ScheduleID/datasources -Headers $headers -Method PUT -Body $body -ContentType "text/xml"
    $response.tsresponse.task.extractRefresh
 }
 catch {"Unable to add Data source to Schedule: " + $ScheduleName + " :- " + $_.Exception.Message}
}

function TS-AddWorkbookToSchedule
{
param(
[string[]] $ScheduleName ="",
[string[]] $WorkbookName ="",
[string[]] $ProjectName ="",
[string[]] $ScheduleID ="",
[string[]] $WorkbookID =""
)
try
 {
  if ($WorkbookID -ne ''){} else{$WorkbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
  if ($ScheduleID -ne ''){} else{$ScheduleID = TS-GetScheduleDetails -name $ScheduleName}

  $body = '<tsRequest>
    <task>
    <extractRefresh>
      <workbook id="'+$WorkbookID + '" />
    </extractRefresh>
    </task>
  </tsRequest>'

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/schedules/$ScheduleID/workbooks -Headers $headers -Method PUT -Body $body -ContentType "text/xml"
    $response.tsresponse.task.extractRefresh
 }
 catch {"Unable to add Workbook to Schedule: " + $ScheduleName + " :- " + $_.Exception.Message}
}


Function TS-QueryJobs
 {
    param
  (
   [string[]] $Filter ="")

 try
  {
    if ($Filter -ne '') {$Filter += "&filter="+ $Filter }
        
    $PageSize = 100
    $PageNumber = 1
    $done = 'FALSE'

    While ($done -eq 'FALSE')
     {
        $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/jobs?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

        $totalAvailable = $response.tsResponse.pagination.totalAvailable

        If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

         $PageNumber += 1

          foreach ($detail in $response.tsResponse.backgroundJobs.backgroundJob)
                { 
                    $detail
                }
        }
  }
   catch {"Unable to Query Jobs: " + $_.Exception.Message}
}

Function TS-QueryJob
 {
    param
  (
   [string[]] $JobID ="")

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/jobs/$JobID -Headers $headers -Method GET
    $detail = $response.tsResponse.job
    $Job = [pscustomobject]@{Type=$detail.type; Mode=$detail.mode; Progress=$detail.progress; CreatedAt=$detail.CreatedAt; StartedAt=$detail.StartedAt; CompletedAt=$detail.CompletedAt; Workbook = $detail.extractrefreshjob.workbook.name; DataSource = $detail.extractrefreshjob.datasource.name; FinishCode=$detail.finishcode; Notes = $detail.extractrefreshjob.notes; ID = $detail.id}
    $Job

 }

Function TS-CancelJob
 {
    param
  (
   [string[]] $JobID ="")

try
 {
      #$body = "<tsRequest></tsRequest>"
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/jobs/$JobID -Headers $headers -Method PUT # -Body $body
    $response.tsresponse
  }
    catch {"Unable to Cancel Job: " + $_.Exception.Message}


 }



function TS-DownloadWorkbook
{
  param
  (
  [string[]] $WorkbookName ="",
  [string[]] $ProjectName ="",
  [string[]] $FileName ="",
  [validateset('True', 'False')][string[]] $IncludeExtract ="",
  [string[]] $WorkbookID = ""
  )
  try {
    if (!($WorkbookID)) {$WorkbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName} else {$WorkbookName = TS-GetWorkbookDetails -ID $workbookID}
    $suffix = ""
    if ($IncludeExtract -ne ''){$suffix = '?includeExtract='+$IncludeExtract}

    $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/workbooks/" + $WorkbookID + "/content" + $suffix

    #$wc = New-Object System.Net.WebClient
    $wc = New-Object ExtendedWebClient
    $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
    $wc.DownloadFile($url, $FileName)
    "Workbook " + $WorkbookName + " downloaded successfully to " + $FileName
  }
  catch {"Unable to download workbook. " + $WorkbookName + " :- " + $_.Exception.Message}
}

function TS-DownloadWorkbookRevision
{
  param
  (
  [string[]] $WorkBookName ="",
  [string[]] $ProjectName ="",
  [string[]] $FileName ="",
  [string[]] $RevisionNumber,
  [validateset('True', 'False')][string[]] $IncludeExtract ="",
  [string[]] $WorkbookID = ""
  )
  try {
    if (!($WorkbookID)) {$WorkbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
    $suffix = ""
    if ($IncludeExtract -ne ''){$suffix = '?includeExtract='+$IncludeExtract}

    $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/workbooks/" + $WorkbookID + "/revisions/" + $RevisionNumber + "/content" + $suffix
    #$wc = New-Object System.Net.WebClient
    $wc = New-Object ExtendedWebClient
    $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
    $wc.DownloadFile($url, $FileName)
    "Workbook " + $WorkbookName + " downloaded successfully to " + $FileName
  }
  catch {"Unable to download workbook revision. " + $WorkBookName + " :- " + $_.Exception.Message}
}



function TS-DownloadDataSource
{
  param
  (
  [string[]] $DatasourceName ="",
  [string[]] $ProjectName ="",
  [string[]] $FileName ="",
  [validateset('True', 'False')][string[]] $IncludeExtract ="",
  [string[]] $DataSourceID = ""
  )
  try {
    if (!($DataSourceID)) { $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
    $suffix = ""
    if ($IncludeExtract -ne ''){$suffix = '?includeExtract='+$IncludeExtract}
    $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/DataSources/" + $DataSourceID + "/content"+ $suffix

    #$wc = New-Object System.Net.WebClient
    $wc = New-Object ExtendedWebClient
    $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
    $wc.DownloadFile($url, $FileName)
    "Data Source " + $DatasourceName + " download successfully to " + $FileName
  }
  catch {"Unable to download datasource. " + $DatasourceName + " :- " + $_.Exception.Message }
}

function TS-DownloadDataSourceRevision
{
  param
  (
  [string[]] $DatasourceName ="",
  [string[]] $ProjectName ="",
  [string[]] $FileName ="",
  [string[]] $RevisionNumber,
  [validateset('True', 'False')][string[]] $IncludeExtract ="",
  [string[]] $DataSourceID = ""
  )
  try {
    if (!($DataSourceID)) { $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
    $suffix = ""
    if ($IncludeExtract -ne ''){$suffix = '?includeExtract='+$IncludeExtract}
    $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/DataSources/" + $DataSourceID + "/revisions/" + $RevisionNumber + "/content"+ $suffix

    #$wc = New-Object System.Net.WebClient
    $wc = New-Object ExtendedWebClient
    $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
    $wc.DownloadFile($url, $FileName)
    "Data Source " + $DatasourceName + " download successfully to " + $FileName
  }
  catch {"Unable to download datasource revision. " + $DatasourceName + " :- " + $_.Exception.Message}
}



function TS-QueryViewsForSite
{

  param
  (
   [string[]] $Filter ="")

    if ($Filter -ne '') {$Filter += "&filter="+ $Filter }

  try
  {
   $PageSize = 100
   $PageNumber = 1
   $done = 'FALSE'

   While ($done -eq 'FALSE')
    {
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views?$filter`&includeUsageStatistics=true`&pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

     $PageNumber += 1
     ForEach ($detail in $response.tsResponse.Views.view)
      { 
       $WorkbookName = TS-GetWorkbookDetails -ID $detail.workbook.id
       $ProjectName = TS-GetWorkbookProject -ID $detail.workbook.id
       $Owner = TS-GetUserDetails -ID $detail.owner.id
       $viewURL = TS-GetViewURL -ContentURL $detail.contentURL
       $Views = [pscustomobject]@{ViewName=$detail.name; ViewCount=$detail.usage.TotalViewCount; Owner=$Owner; WorkbookName = $workbookName; ProjectName = $ProjectName; ContentURL=$detail.contentURL; ViewURL= $viewURL; ID = $detail.id}
       $views
      }
    }
  }
  catch {"Unable to Query Views" + " :- " + $_.Exception.Message}
}

function TS-QueryViewsForWorkbook
{
  param(
  [string[]] $WorkbookName = "",
  [string[]] $ProjectName = "",
  [string[]] $WorkbookID = ""
  )
  try {
    if (!($WorkbookID)) {$WorkbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/views?includeUsageStatistics=true -Headers $headers -Method Get

    ForEach ($detail in $response.tsResponse.Views.view)
    {
      $viewURL = TS-GetViewURL -ContentURL $detail.contentURL

      $Views = [pscustomobject]@{ViewName=$detail.name; ViewCount=$detail.usage.TotalViewCount; ContentURL=$detail.contentURL; ViewURL= $viewURL}
      $views
    }
  }
  catch {"Unable to Query Views for Workbook: " + $WorkbookName + " :- " + $_.Exception.Message}
}

function TS-GetViewURL
{
  param
  (
   [string[]] $ContentURL =""
  )
  $ViewURL = $contentURL.Replace("/sheets/","/")
  $Site_Details = TS-QuerySite
  $site_ID = $site_Details.contentURL

  if ($Site_Details.contentURL -eq "")
   {
     $URL ="$protocol`://$server/#/views/$ViewURL"
     Return $URL
   }
  else
   {
     $URL = "$protocol`://$server/#/site/$site_ID/views/$ViewURL"
     Return $URL
   } 
}




function TS-QueryWorkbooksForUser
{
  param
  (
   [string[]] $UserAccount ="",
   [validateset('True', 'False')][string[]][string[]] $IsOwner ="False"
  )
 try
 {

  if (-not($UserAccount)){$UserAccount = $userName}

  $userId = TS-GetUserDetails -Name $UserAccount
 
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/users/$userId/workbooks?ownedBy=$IsOwner`&pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.workbooks.workbook)
     {
      $taglist =''
      $ProjectName = TS-GetProjectDetails -ProjectID $detail.Project.ID
      $Owner = TS-GetUserDetails -ID $detail.Owner.ID

      ForEach ($tag in $detail.tags.tag.label){$taglist += $tag + " "}

      $Workbooks = [pscustomobject]@{WorkbookName=$detail.name; ShowTabs=$detail.ShowTabs; ContentURL=$detail.contentURL; Size=$detail.size; CreatedAt=$detail.CreatedAt; UpdatedAt=$detail.UpdatedAt; Project=$ProjectName; Owner=$Owner; Tags=$taglist}
      $workbooks
     }
   }
 }
 catch {"Unable to Query Workbooks for User :- " + $_.Exception.Message}
}


function TS-QueryWorkbooksForSite
{
  param
  (
   [string[]] $Filter ="")

    if ($Filter -ne '') {$Filter += "&filter="+ $Filter }

  try
 {
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'
  
  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks?$filter`&pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get 

    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.workbooks.workbook)
     {
      $taglist =''
      $ProjectName = TS-GetProjectDetails -ProjectID $detail.Project.ID
      $Owner = TS-GetUserDetails -ID $detail.Owner.ID

      ForEach ($tag in $detail.tags.tag.label){$taglist += $tag + " "}

      $Workbooks = [pscustomobject]@{WorkbookName=$detail.name; ShowTabs=$detail.ShowTabs; ContentURL=$detail.contentURL; Size=$detail.size; CreatedAt=$detail.CreatedAt; UpdatedAt=$detail.UpdatedAt; Project=$ProjectName; Owner=$Owner; Tags=$taglist; EncryptExtracts=$detail.encryptExtracts; ID=$detail.ID}
      $workbooks
     }
   }
 }
 catch {"Unable to Query Workbooks for Site :- " + $_.Exception.Message}
}

function TS-GetWorkbookDetails
{

  param(
 [string[]] $Name = "",
 [string[]] $ID = "",
 [string[]] $ProjectName = ""
 )

 $PageSize = 100
 $PageNumber = 1
 $done = 'FALSE'

 While ($done -eq 'FALSE')
 {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

   $totalAvailable = $response.tsResponse.pagination.totalAvailable

   If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

   $PageNumber += 1

   foreach ($detail in $response.tsResponse.workbooks.workbook)
    {
     if ($Name -eq $detail.name -and $ProjectName -eq $detail.project.name){Return $detail.ID}
     if ($ID -eq $detail.ID){Return $detail.Name}
    }
 }
}

function TS-GetWorkbookProject
{

  param(
 [string[]] $ID = ""
 )

 $PageSize = 100
 $PageNumber = 1
 $done = 'FALSE'

 While ($done -eq 'FALSE')
 {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

   $totalAvailable = $response.tsResponse.pagination.totalAvailable

   If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

   $PageNumber += 1

   foreach ($detail in $response.tsResponse.workbooks.workbook)
    {
     if ($ID -eq $detail.ID){Return $detail.project.name}
    }
 }
}


function TS-QueryWorkbook
{
  param(
  [string[]] $WorkbookName,
  [string[]] $ProjectName,
  [string[]] $WorkbookID = ""
  )
  try {
    if (!($WorkbookID)) {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID -Headers $headers -Method Get
  
    ForEach ($detail in $response.tsResponse.workbook)
    {
      $taglist =''
      $ProjectName = TS-GetProjectDetails -ProjectID $detail.Project.ID
      $Owner = TS-GetUserDetails -ID $detail.Owner.ID

      ForEach ($tag in $detail.tags.tag.label){$taglist += $tag + " "}
      $Workbook = [pscustomobject]@{WorkbookName = $WorkbookName.Trim();ShowTabs=$detail.ShowTabs; ContentURL=$detail.contentURL; Size=$detail.size; CreatedAt=$detail.CreatedAt; UpdatedAt=$detail.UpdatedAt; Project=$ProjectName; Owner=$Owner; Tags=$detail.tags.tag.label; Views = $detail.Views.View.Count; ViewList =$detail.Views.View.name; ID = $WorkbookID}
    }
    $workbook
  }
  catch {"Unable to Query Workbook: " + $WorkbookName + " :- " + $_.Exception.Message}
}

function TS-QueryWorkbookConnections
{
  param(
  [string[]] $WorkbookName,
  [string[]] $ProjectName,
  [string[]] $WorkbookID = ""
  )

  try {
    if (!($WorkbookID)) {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID/connections -Headers $headers -Method Get

    ForEach ($detail in $response.tsResponse.Connections.connection)
    {
      $Connections = [pscustomobject]@{Id=$detail.id; Type=$detail.type; ServerAddress=$detail.serverAddress; ServerPort=$detail.serverPort;UserName=$detail.userName;DataSourceID=$detail.datasource.Id;DataSourceName=$detail.datasource.name}
      $Connections`
    }
  }
  catch {"Unable to Query Workbook connections." + " :- " + $_.Exception.Message}
}


function TS-UpdateWorkbook
{
  param(
  [string[]] $WorkbookName = "",
  [string[]] $ProjectName = "",
  [string[]] $NewProjectName = "",
  [string[]] $NewOwnerAccount = "",
  [validateset('True', 'False')][string[]] $ShowTabs = "",
  [string[]] $WorkbookID = ""

  )
  try {
    if (!($WorkbookID)) {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
    $userID = TS-GetUserDetails -name $NewOwnerAccount
    $ProjectID = TS-GetProjectDetails -ProjectName $NewProjectName

    $body = ""
    $tabsbody = ""

    if ($ShowTabs -ne '') {$tabsbody += ' showTabs ="'+ $ShowTabs +'"'}
    if ($NewProjectName -ne '') {$body += '<project id ="'+ $ProjectID +'" />'}
    if ($NewOwnerAccount -ne '') {$body += '<owner id ="'+ $userID +'"/>'}

    $body = ('<tsRequest><workbook' +$tabsbody + '>' + $body +  ' </workbook></tsRequest>')

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID -Headers $headers -Method PUT -Body $body
    $response.tsResponse.Workbook
  }
  catch {"Problem updating Workbook: " + $WorkbookName + " :- " + $_.Exception.Message}
}

function TS-UpdateWorkbookNow
{
  param(
  [string[]] $WorkbookName ="",
  [string[]] $ProjectName ="",
  [string[]] $WorkbookID = ""
  )
  if (!($WorkbookID)) {$WorkbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}

  $body = "<tsRequest></tsRequest>"
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID/refresh -Headers $headers -Method POST -Body $body -ContentType "text/xml"
  $response.tsresponse.job
}


function TS-UpdateDataSourceNow
{
  param(
  [string[]] $DataSourceName ="",
  [string[]] $ProjectName ="",
  [string[]] $DataSourceID = ""
  )
  if (!($DataSourceID)) { $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}

  $body = "<tsRequest></tsRequest>"
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/refresh -Headers $headers -Method POST -Body $body -ContentType "text/xml"
  $response.tsresponse.job
}


function TS-DeleteWorkbook
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $WorkbookID = ""
 )
 try
  {
    if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$WorkbookID -Headers $headers -Method DELETE 
   "Workbook Deleted"
  }
  catch{"Unable to Delete Workbook: " + $WorkbookName}
}

function TS-AddTagsToWorkbook
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $Tags = "",
 [string[]] $WorkbookID = ""

 )
 try
 {

    if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
  $workbookID

  $body = ''
  $TagsArrary = $Tags.Split(",")
  Foreach ($Tag in $TagsArrary) {$body += '<tag label ="'+ $Tag +'" />'}
 
  $body = ('<tsRequest><tags>'  + $body +  ' </tags></tsRequest>')

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID/tags -Headers $headers -Method Put -Body $body
  $response.tsResponse.tags.tag
 }
 catch {"Problem adding tags to Workbook:" + $WorkbookName}
}

function TS-AddTagsToView
{
 param(
 [string[]] $ViewName = "",
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $Tags = "",
 [string[]] $WorkbookID = ""
 )
 try
 {

  $ViewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName
 
  $body = ''
  $TagsArrary = $Tags.Split(",")
  Foreach ($Tag in $TagsArrary) {$body += '<tag label ="'+ $Tag +'" />'}
 
  $body = ('<tsRequest><tags>'  + $body +  ' </tags></tsRequest>')

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views/$ViewID/tags -Headers $headers -Method Put -Body $body
  $response.tsResponse.tags.tag
 }
 catch {"Problem adding tags to View:" + $ViewName}
}

function TS-AddTagsToDataSource
{
 param(
 [string[]] $DataSourceName = "",
 [string[]] $ProjectName = "",
 [string[]] $Tags = "",
 [string[]] $DataSourceID = ""
 )
 try
 {
     if ($DataSourceID -ne ''){ $DataSourceID} else { $DataSourceID = TS-getDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
  $DataSourceID

  $body = ''
  $TagsArrary = $Tags.Split(",")
  Foreach ($Tag in $TagsArrary) {$body += '<tag label ="'+ $Tag +'" />'}
 
  $body = ('<tsRequest><tags>'  + $body +  ' </tags></tsRequest>')

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/tags -Headers $headers -Method Put -Body $body
  $response.tsResponse.tags.tag
 }
 catch {"Problem adding tags to DataSource:" + $DataSourceName + " :- " + $_.Exception.Message}
}


function TS-DeleteTagFromWorkbook
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $Tag = "",
 [string[]] $WorkbookID = ""
 )
 try
 {
    if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
  $workbookID
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID/tags/$Tag -Headers $headers -Method Delete
 }
 catch {"Problem removing tag from Workbook:" + $WorkbookName + " :- " + $_.Exception.Message}
}

function TS-DeleteTagFromDataSource
{
 param(
 [string[]] $DataSourceName = "",
 [string[]] $ProjectName = "",
 [string[]] $Tag = "",
 [string[]] $DataSourceID = ""
 )
 try
 {
    if ($DataSourceID -ne ''){ $DataSourceID} else { $DataSourceID = TS-getDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
  $DataSourceID
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/tags/$Tag -Headers $headers -Method Delete
 }
 catch {"Problem removing tag from DataSource:" + $DataSourceName + " :- " + $_.Exception.Message}
}

function TS-DeleteTagFromView
{
 param(
 [string[]] $ViewName = "",
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $Tag = ""
 )

 try
 {
  $ViewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName
  $ViewID
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views/$ViewID/tags/$Tag -Headers $headers -Method Delete
 }
 catch {"Problem removing tag from View:" + $ViewName + " :- " + $_.Exception.Message}
}

function TS-GetViewDetails
{

  param(
 [string[]] $ViewName = "",
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $WorkbookID = ""
 )

 if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
 
 $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID/Views -Headers $headers -Method Get

 foreach ($detail in $response.tsResponse.Views.View)
  {
   if ($ViewName -eq $detail.name){Return $detail.ID}
  }
}


function TS-GetViewName
{
  param(
 [string[]] $ViewID = ""
  )
   $PageSize = 100
   $PageNumber = 1
   $done = 'FALSE'

   While ($done -eq 'FALSE')
    {
     $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/views?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
     $totalAvailable = $response.tsResponse.pagination.totalAvailable

     If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

     $PageNumber += 1
     foreach ($detail in $response.tsResponse.views.view)
      {
        if ($ViewID -eq $detail.ID){Return $detail.name}
      }
   }
}


####### Favourites

function TS-AddWorkbookToFavorites
{
 param(

 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $UserAccount = "",
 [string[]] $Label = "",
 [string[]] $WorkbookID = ""
 )
 try
 {
   if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
  $userID = TS-GetUserDetails -name $UserAccount

   $body = '<tsRequest>
   <favorite label="' +$label +'">
    <workbook id="' + $workbookID +'" />
   </favorite>
   </tsRequest>'
 
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID -Headers $headers -Method Put -Body $body
   "Workbook added to Favorites"
  }
  catch {"Unable To Add Workbook to Favorites." + " :- " + $_.Exception.Message}
}

function TS-AddViewToFavorites
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $ViewName = "",
 [string[]] $UserAccount = "",
 [string[]] $Label = ""
 )

 try
  {
   $ViewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName
   $userID = TS-GetUserDetails -name $UserAccount

   $body = '<tsRequest>
   <favorite label="' +$label +'">
    <view id="' + $viewID +'" />
   </favorite>
   </tsRequest>'
 
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID -Headers $headers -Method Put -Body $body
   "View Added to Favorites"
  }
  catch {"Unable to Add View to Favorites." + " :- " + $_.Exception.Message}
}

function TS-DeleteWorkbookFromFavorites
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $UserAccount = "",
 [string[]] $WorkbookID = ""
 )

 try
  {

    if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
   $userID = TS-GetUserDetails -name $UserAccount

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID/workbooks/$WorkbookID -Headers $headers -Method Delete
   "Workbook removed from Favorites"

  }
  catch {"Unable to Delete Workbook From Favorites." + " :- " + $_.Exception.Message}
}

function TS-DeleteViewFromFavorites
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $ViewName = "",
 [string[]] $UserAccount = ""
 )

 try
  {
   $viewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName
   $userID = TS-GetUserDetails -name $UserAccount
   
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID/views/$ViewID -Headers $headers -Method Delete
   "View removed from Favorites"
  }
  catch {"Unable to Delete View From Favorites." + " :- " + $_.Exception.Message}
}


function TS-AddDataSourceToFavorites
{
 param(

 [string[]] $DataSourceName = "",
 [string[]] $ProjectName = "",
 [string[]] $UserAccount = "",
 [string[]] $Label = "",
 [string[]] $DataSourceID = ""
 )
 try
 {
   if ($DataSourceID -ne '') {$DataSourceID} else {$DataSourceID = TS-GetDatasourceDetails -Name $DataSourceName -ProjectName $ProjectName}
   $userID = TS-GetUserDetails -name $UserAccount

   $body = '<tsRequest>
   <favorite label="' +$label +'">
    <datasource id="' + $DataSourceID +'" />
   </favorite>
   </tsRequest>'
 
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID -Headers $headers -Method Put -Body $body
   "DataSource added to Favorites"
  }
  catch {"Unable To Add DataSource to Favorites." + " :- " + $_.Exception.Message}
}


function TS-DeleteDataSourceFromFavorites
{
 param(
 [string[]] $DataSourceName = "",
 [string[]] $ProjectName = "",
 [string[]] $UserAccount = "",
 [string[]] $DataSourceID = ""
 )

 try
  {

   if ($DataSourceID -ne '') {$DataSourceID} else {$DataSourceID = TS-GetDatasourceDetails -Name $DataSourceName -ProjectName $ProjectName}
   $userID = TS-GetUserDetails -name $UserAccount

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID/datasources/$DataSourceID -Headers $headers -Method Delete
   "DataSource removed from Favorites"

  }
  catch {"Unable to delete DataSource From Favorites." + " :- " + $_.Exception.Message}
}


function TS-AddProjectToFavorites
{
 param(
 [string[]] $ProjectName = "",
 [string[]] $UserAccount = "",
 [string[]] $Label = "",
 [string[]] $ProjectID = ""
 )
 try
 {
   if ($ProjectID -ne '') {$ProjectID} else {$ProjectID = TS-GetProjectDetails -ProjectName $ProjectName}
   $userID = TS-GetUserDetails -name $UserAccount

   $body = '<tsRequest>
   <favorite label="' +$label +'">
    <project id="' + $ProjectID +'" />
   </favorite>
   </tsRequest>'
 
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID -Headers $headers -Method Put -Body $body
   "Project added to Favorites"
  }
  catch {"Unable To Add Project to Favorites." + " :- " + $_.Exception.Message}
}


function TS-DeleteProjectFromFavorites
{
 param(
 [string[]] $ProjectName = "",
 [string[]] $UserAccount = "",
 [string[]] $ProjectID = ""
 )

 try
  {

   if ($ProjectID -ne '') {$ProjectID} else {$ProjectID = TS-GetProjectDetails -ProjectName $ProjectName}
   $userID = TS-GetUserDetails -name $UserAccount

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/favorites/$userID/projects/$ProjectID -Headers $headers -Method Delete
   "Project removed from Favorites"

  }
  catch {"Unable to delete Project From Favorites." + " :- " + $_.Exception.Message}
}

Function TS-QueryWorkbookPreviewImage
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $FileName = "",
 [string[]] $WorkbookID = ""
 )
 try
  {
   if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}

   $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/workbooks/" + $workbookID + "/previewImage"
   #$wc = New-Object System.Net.WebClient
   $wc = New-Object ExtendedWebClient
   $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
   $wc.DownloadFile($url, $FileName)
   "File Downloaded: " + $FileName

  }
  catch {"Unable to Query Workbook Preview Image." + " :- " + $_.Exception.Message}
}

Function TS-QueryViewPreviewImage
{
param(
 [string[]] $ViewName = "",
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $FileName = "",
 [string[]] $WorkbookID = ""
 )
 try
  {
     if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
  $viewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName

   $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/workbooks/" + $workbookID + "/views/" + $viewID + "/previewImage"
   
   #$wc = New-Object System.Net.WebClient
   $wc = New-Object ExtendedWebClient
   $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
   $wc.DownloadFile($url, $FileName)
   "File Downloaded: " + $FileName
  }
  catch {"Unable to Query View Preview Image." + " :- " + $_.Exception.Message}
}



Function TS-QueryViewDownload
{
 param(
 [string[]] $ViewName = "",
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $FileName = "None",
 [validateset('Normal', 'High')][string[]] $ImageQuality = "Normal",
 [validateset('data', 'image', 'pdf')][string[]] $Type = "",
 [string[]] $ViewFilters = "",
 [string[]] $ViewID = ""
 
 )
 try
  {
    if ($ViewID -ne '') {$ViewID} else {$viewID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName}
   $suffix = $Type
   $join = "?"
   If ($Type -eq "image" -and $ImageQuality -eq "High")
    {
      $Suffix = "image?resolution=high"
      $Join = "&"
    }
   $vf_filter = ""

   if ($ViewFilters -ne '')
    {
      $ViewFilters = $ViewFilters.replace("&","&vf_")
      $vf_filter += $join + "vf_"+$ViewFilters
    }

   $url = $protocol.trim() + "://" + $server +"/api/" + $api_ver+ "/sites/" + $siteID + "/views/" + $viewID + "/" + $Suffix + $vf_filter
   $url

   if ($FileName -eq "None")
     { 
      $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
     }
    else
     {
      #$wc = New-Object System.Net.WebClient
      $wc = New-Object ExtendedWebClient
      $wc.Headers.Add('X-Tableau-Auth',$headers.Values[0])
      $wc.DownloadFile($url, $FileName)
      "File Downloaded: " + $FileName
     }
  }
  catch {"Unable to download View as " + $Type + " :- " + $_.Exception.Message }
}



function TS-GetDataSourceRevisions
{
 param(
 [string[]] $DataSourceName = "",
 [string[]] $ProjectName = "",
 [string[]] $DataSourceID = "" 
 )
 try
 {
     if ($DataSourceID -ne ''){ $DataSourceID} else { $DataSourceID = TS-getDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName}
  
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   {
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$DataSourceID/revisions?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1


    ForEach ($detail in $response.tsResponse.revisions.revision)
    {
     $Revisions = [pscustomobject]@{DataSourceName=$DataSourceName; Project=$ProjectName; RevisionNumber=$detail.revisionnumber; PublishedAt=$detail.publishedAt; IsDeleted=$detail.deleted; IsCurrent=$detail.current;Size=$detail.SizeinBytes; Publisher=$detail.publisher.name}
     $Revisions
    }
   }
  }
  catch {"Unable to Get Datasource Revisions" + " :- " + $_.Exception.Message}
 }

function TS-GetWorkbookRevisions
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $WorkbookID = "" 
 )
 try
 {
   if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}

  
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   {
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID/revisions?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1


    ForEach ($detail in $response.tsResponse.revisions.revision)
    {
     $Revisions = [pscustomobject]@{WorkbookName=$WorkbookName; Project=$ProjectName; RevisionNumber=$detail.revisionnumber; PublishedAt=$detail.publishedAt; IsDeleted=$detail.deleted; IsCurrent=$detail.current;Size=$detail.SizeinBytes; Publisher=$detail.publisher.name}
     $Revisions
    }
   }
  } 
  catch {"Unable to Get Workbook Revisions" + " :- " + $_.Exception.Message}
 }

function TS-RemoveWorkbookRevision
{
 param(
 [string[]] $WorkbookName = "",
 [string[]] $ProjectName = "",
 [string[]] $RevisionNumber ="",
 [string[]] $WorkbookID = ""
 )
 try
 {
    if ($WorkbookID -ne '') {$WorkbookID} else {$workbookID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName}
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/workbooks/$workbookID/revisions/$RevisionNumber -Headers $headers -Method Delete
  "Removed Workbook Revision: " + $RevisionNumber
  }
  catch {"Unable to remove Workbook Revision: " + $RevisionNumber  }
 }


function TS-RemoveDataSourceRevision
{
 param(
 [string[]] $DataSourceName = "",
 [string[]] $ProjectName = "",
 [string[]] $RevisionNumber =""
 )
try
 {
  $DataSourceID = TS-GetDataSourceDetails -Name $DataSourceName -ProjectName $ProjectName
  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/datasources/$datasourceID/revisions/$RevisionNumber -Headers $headers -Method Delete
  "Removed Datasource Revision: " + $RevisionNumber
 }
  catch {"Unable to remove Datasource Revision: " + $RevisionNumber + " :- " + $_.Exception.Message }
 }

 
### Manage Subscriptions

function TS-CreateSubscription
{
param(
 [string[]] $Subject = "",
 [validateset('Workbook','View')][string[]] $Type = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Schedule = "",
 [string[]] $UserName = ""
 
 )
 try
  {

  If($Type -eq 'View')
   {
     $ContentID = TS-GetViewDetails -WorkbookName $WorkbookName -ProjectName $ProjectName -ViewName $ViewName
   }
  else
   {
    $ContentID = TS-GetWorkbookDetails -Name $WorkbookName -ProjectName $ProjectName
   }

  $ScheduleID = TS-GetScheduleDetails -name $Schedule
  $UserID = TS-GetUserDetails -name $UserName

  $ContentID
  $scheduleID
  $UserID


  $Body = '<tsRequest>
  <subscription subject="' + $subject +'">
    <content type="' + $Type + '" id="' + $ContentID +'"  />
    <schedule id="' + $ScheduleID + '" />
    <user id="' + $UserID + '" />
  </subscription>
  </tsRequest>'

   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/subscriptions -Headers $headers -Method POST -Body $Body 
   $response.tsresponse.subscription 
 
 }
 catch {"Unable to Create Subscription" + " :- " + $_.Exception.Message}

}


function TS-QuerySubscriptions
{
  try
 {
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/subscriptions?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.subscriptions.subscription)
     {
        
        if ($detail.content.type -eq 'View')
         {
          $ViewID = $detail.content.id

          $ContentName = TS-GetViewName -ViewID  $ViewID 
         } 
         else
         {
          $ContentName = TS-GetWorkbookDetails -ID $detail.content.id
         }
        
        $Subscriptions = [pscustomobject]@{Subject=$detail.subject; User=$detail.user.name; Schedule=$detail.schedule.name; Type=$detail.content.type; ContentName=$ContentName; ID=$detail.ID}
        $Subscriptions
     }
   }
 }
 catch {"Unable to Query Subscriptions for Site" + " :- " + $_.Exception.Message}
}



function TS-DeleteSubscription
{
param(
 [string[]] $Subject = "",
 [validateset('Workbook','View')][string[]] $Type = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Schedule = "",
 [string[]] $UserName = "",
 [string[]] $SubscriptionID = ""

 )

  if ($SubscriptionID -ne '') {$SubscriptionID} else {$SubscriptionID = TS-GetSubscriptionDetails -Subject $Subject -Type $Type -WorkbookName $WorkbookName -ViewName $ViewName -UserName $UserName -Schedule $Schedule}
  try
  {
    $SubscriptionID
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/subscriptions/$SubscriptionID -Headers $headers -Method Delete
   "Subscription Deleted"
  }
  catch {"Unable to Delete Subscription :- " + $_.Exception.Message}
}

function TS-UpdateSubscription
{
param(
 [string[]] $Subject = "",
 [validateset('Workbook','View')][string[]] $Type = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $Schedule = "",
 [string[]] $UserName = "",
 [string[]] $NewSubject = "",
 [string[]] $NewSchedule = "",
 [string[]] $SubscriptionID = ""

 )
 try
  {

  if ($SubscriptionID -ne '') {$SubscriptionID} else {$SubscriptionID = TS-GetSubscriptionDetails -Subject $Subject -Type $Type -WorkbookName $WorkbookName -ViewName $ViewName -UserName $UserName -Schedule $Schedule}
  if ($NewSubject -ne '') {} else {$NewSubject  = $Subject}

     $body1 = ""
   if ($NewSubject -ne '') {$body1 += ' subject="'+ $NewSubject +'"'}
   if ($NewSchedule -ne '')
     {
       $NewScheduleID = TS-GetScheduleDetails -name $NewSchedule
       $body2 = ' <schedule id="'+ $NewScheduleID +'" />'
     }

   $body = ('<tsRequest>
   <subscription' + $body1 +">"+ $body2 +' </subscription>
   </tsRequest>')
   $body



 
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/subscriptions/$SubscriptionID -Headers $headers -Method PUT -Body $Body  -ContentType "text/xml"
   $response.tsresponse.subscription 
 
 }
 catch {"Unable to Update Subscription" + " :- " + $_.Exception.Message}

}

function TS-GetSubscriptionDetails
{
  param(
 [string[]] $Subject = "",
 [validateset('Workbook','View')][string[]] $Type = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $Schedule = "",
 [string[]] $UserName = ""
 )

  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/subscriptions?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.subscriptions.subscription)
     { 

        If ($detail.content.type -eq $Type)
         {
          if ($detail.content.type -eq 'View')
           {
            $ContentName = TS-GetViewName -ViewID $detail.content.id
           } 
          else
          {
           $ContentName = TS-GetWorkbookDetails -ID $detail.content.id
          }
         }
        If (($ContentName -eq $WorkbookName -or $contentName -eq $ViewName) -and $Schedule -eq $detail.schedule.name -and $UserName -eq $detail.user.name -and $Subject -eq $detail.subject)
         {
            Return $detail.id
         }
     }
   }
}

### Manage Data Driven Alerts
Function TS-QueryDataDrivenAlerts
{
  try
 {
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/dataAlerts?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.dataAlerts.dataAlert)
     {
        $Creator = TS-GetUserDetails -ID $detail.creatorID

        $DataDrivenAlerts = [pscustomobject]@{Subject=$detail.subject; 
        Owner=$detail.owner.name; 
        Frequency=$detail.frequency; 
        View=$detail.view.name; 
        Workbook=$detail.view.workbook.name; 
        Project=$detail.view.project.name; 
        CreatedAt=$detail.createdAt;
        UpdatedAt=$detail.updatedAt;
        Creator = $Creator;
        ID=$detail.ID}
        $DataDrivenAlerts
     }
   }
 }
 catch {"Unable to Query Data Driven Alerts for Site" + " :- " + $_.Exception.Message}
}

Function TS-QueryDataDrivenAlertDetails
{
  param(
 [string[]] $Subject = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Frequency = "",
 [string[]] $AlertID = ""
 )

 try
  {
   if ($AlertID -ne '') {$AlertID} else {$AlertID = TS-GetDataDrivenAlertDetails -Subject $Subject -WorkbookName $WorkbookName -ViewName $ViewName -ProjectName $ProjectName -Frequency $Frequency}
 
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/dataAlerts/$AlertID -Headers $headers -Method Get
     $detail= $response.tsresponse.dataAlert
     $Creator = TS-GetUserDetails -ID $detail.creatorID

     ForEach ($recipientID in $detail.recipients.recipient.id)
      {
       $recipientName = TS-GetUserDetails -ID $recipientID 
       $recipientList += $recipientName +";"
      }



        $DataDrivenAlerts = [pscustomobject]@{Subject=$detail.subject; 
        Owner=$detail.owner.name; 
        Frequency=$detail.frequency; 
        View=$detail.view.name; 
        Workbook=$detail.view.workbook.name; 
        Project=$detail.view.project.name; 
        CreatedAt=$detail.createdAt;
        UpdatedAt=$detail.updatedAt;
        Creator = $Creator;
        Recipients = $recipientlist
        ID=$detail.ID}
        $DataDrivenAlerts
   }
  catch {"Unable to Query Data Driven Alert :- " + $_.Exception.Message}
  

}

Function TS-AddUserToDataDrivenAlert
{
  param(
 [string[]] $Subject = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Frequency = "",
 [string[]] $UserAccount = "",
 [string[]] $AlertID = "",
 [string[]] $UserID = ""

 )
  try
   {
   
    if ($AlertID -ne '') {$AlertID} else {$AlertID = TS-GetDataDrivenAlertDetails -Subject $Subject -WorkbookName $WorkbookName -ViewName $ViewName -ProjectName $ProjectName -Frequency $Frequency}
    if ($UserID -ne '') {$UserID} else {$userID = TS-GetUserDetails -name $UserAccount}

      $body = '<tsRequest>
    <user id="' +$UserID+ '"/>
    </tsRequest>'

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/dataAlerts/$AlertID/users -Headers $headers -Method POST -Body $body
    "User Added to Data Driven Alert"
   }
   catch {"Unable to add user to Data Driven Alert :- " + $_.Exception.Message}

}
Function TS-DeleteUserFromDataDrivenAlert
{
  param(
 [string[]] $Subject = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Frequency = "",
 [string[]] $UserAccount = "",
 [string[]] $AlertID = "",
 [string[]] $UserID = ""

 )
  try
   {
   
    if ($AlertID -ne '') {$AlertID} else {$AlertID = TS-GetDataDrivenAlertDetails -Subject $Subject -WorkbookName $WorkbookName -ViewName $ViewName -ProjectName $ProjectName -Frequency $Frequency}
    if ($UserID -ne '') {$UserID} else {$userID = TS-GetUserDetails -name $UserAccount}

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/dataAlerts/$AlertID/users/$UserID -Headers $headers -Method DELETE
    "User Deleted from Data Driven Alert"
   }
   catch {"Unable to delete user from Data Driven Alert :- " + $_.Exception.Message}
}

Function TS-UpdateDataDrivenAlert
{
  param(
 [string[]] $Subject = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Frequency = "",
 [string[]] $AlertID = "",
 [validateset('once', 'frequently', 'hourly', 'daily','weekly')][string[]] $NewFrequency = "",
 [string[]] $NewOwner = "",
 [string[]] $NewSubject = ""
 )

 try
  {
   if ($AlertID -ne '') {$AlertID} else {$AlertID = TS-GetDataDrivenAlertDetails -Subject $Subject -WorkbookName $WorkbookName -ViewName $ViewName -ProjectName $ProjectName -Frequency $Frequency}

   $body1 = ""
   $body2 = ""
   if ($NewSubject -ne '') {$body1 += ' subject="'+ $NewSubject +'"'}
   if ($NewFrequency -ne '') {$body1 += ' frequency="'+ $NewFrequency +'"'}
   if ($NewOwner -ne '')
    {
      $NewOwnerID = TS-GetUserDetails -name $NewOwner
      $body2 = '<owner id ="'+ $NewOwnerID +'"/>'
    }

   $body = ('<tsRequest>
   <dataAlert' + $body1 +">"+ $body2 +' </dataAlert>
   </tsRequest>')
   $body
  	
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/dataAlerts/$AlertID -Headers $headers -Method Put -Body $body
   $response.tsresponse.dataAlert
  }
  catch {"Unable to update Data Driven Alert :- " + $_.Exception.Message}
}



Function TS-DeleteDataDrivenAlert
{
  param(
 [string[]] $Subject = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Frequency = "",
 [string[]] $AlertID = ""
 )

  try
   {
    if ($AlertID -ne '') {$AlertID} else {$AlertID = TS-GetDataDrivenAlertDetails -Subject $Subject -WorkbookName $WorkbookName -ViewName $ViewName -ProjectName $ProjectName -Frequency $Frequency}

    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/dataAlerts/$AlertID -Headers $headers -Method DELETE
    "Deleted Data Driven Alert"
   }
   catch {"Unable to delete Data Driven Alert :- " + $_.Exception.Message}
}

Function TS-GetDataDrivenAlertDetails
{
  param(
 [string[]] $Subject = "",
 [string[]] $WorkbookName = "",
 [string[]] $ViewName = "",
 [string[]] $ProjectName = "",
 [string[]] $Frequency = "",
 [string[]] $AlertID = ""
 )

  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/dataAlerts?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

   ForEach ($detail in $response.tsResponse.dataAlerts.dataAlert)
     { 
       If ($Subject -eq $detail.subject -and $Frequency -eq $detail.frequency -and $ViewName -eq $detail.view.name -and  $WorkbookName -eq $detail.view.workbook.name -and $ProjectName -eq $detail.view.project.name)
        {
            Return $detail.id
         }
     }
   }
}

### Manage Flows
Function TS-QueryFlowsForSite
{
  try
 {
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/flows?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.flows.flow)
     {
        $Owner = TS-GetUserDetails -ID $detail.owner.id
        $Flow = [pscustomobject]@{
        Name=$detail.name; 
        Description=$detail.description; 
        WebPageURL=$detail.webpageurl; 
        FileType=$detail.fileType; 
        Project=$detail.project.name; 
        CreatedAt=$detail.createdAt;
        UpdatedAt=$detail.updatedAt;
        Owner = $Owner;
        ID=$detail.ID}

        $Flow
     }
   }
 }
 catch {"Unable to Query Flows for Site :- " + $_.Exception.Message}
}


function TS-QueryFlow
{
 param(
 [string[]] $FlowName,
 [string[]] $ProjectName,
 [string[]] $FlowID = ""
 )
 try
  {
    if ($FlowID -ne '') {$FlowID} else {$FlowID = TS-GetFlowDetails -Name $FlowName -ProjectName $ProjectName}
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/flows/$FlowID -Headers $headers -Method Get
    # $response.tsResponse
   
   ForEach ($detail in $response.tsResponse)
     {
      $ProjectName = TS-GetProjectDetails -ProjectID $detail.flow.Project.ID
      $Owner = TS-GetUserDetails -ID $detail.flow.Owner.ID
      $Flow = [pscustomobject]@{
       Name = $detail.flow.Name;
       ID = $detail.flow.ID;
       Project = $ProjectName;
       Owner = $Owner;
       Description = $detail.flow.description;
       CreatedAt=$detail.flow.createdAt;
       UpdatedAt=$detail.flow.updatedAt;
       WebPageURL=$detail.flow.webpageUrl;
       FileType=$detail.flow.filetype
       FlowStepNames=$detail.flowoutputSteps.flowoutputstep.name
     }
      $Flow
  }
  }
  catch{"Unable to Query Flow: " + $FlowName + " :- " + $_.Exception.Message}
}

function TS-GetFlowDetails
{

param(
 [string[]] $Name = "",
 [string[]] $ID = "",
 [string[]] $ProjectName = ""
 )

 $PageSize = 100
 $PageNumber = 1
 $done = 'FALSE'

 While ($done -eq 'FALSE')
 {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/flows?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get

   $totalAvailable = $response.tsResponse.pagination.totalAvailable

   If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

   $PageNumber += 1

   foreach ($detail in $response.tsResponse.flows.flow)
    {
     if ($Name -eq $detail.name -and $ProjectName -eq $detail.project.name){Return $detail.ID}
     if ($ID -eq $detail.ID){Return $detail.Name}
    }
 }
}

function TS-GetFlowTaskDetails
{

param(
 [string[]] $Name = "",
 [string[]] $ID = ""
 )

 $PageSize = 100
 $PageNumber = 1
 $done = 'FALSE'

 While ($done -eq 'FALSE')
 {
   $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/tasks/runFlow?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
   $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.tasks.task)
     {
     if ($Name -eq $detail.flowRun.schedule.name){Return $detail.flowRun.ID}
     if ($ID -eq $detail.flowRun.ID){Return $detail.flowRun.schedule.name}
    }
 }
}

function TS-RunFlowNow
{
 param(
 [string[]] $FlowName,
 [string[]] $ProjectName,
 [string[]] $FlowID = ""
 )
 try
  {
    if ($FlowID -ne '') {$FlowID} else {$FlowID = TS-GetFlowDetails -Name $FlowName -ProjectName $ProjectName}

    $body = "<tsRequest></tsRequest>"
   
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/flows/$FlowID/run -Headers $headers -Method POST -Body $body -ContentType "text/xml"
    $response.tsresponse.job
 
  }
  catch{"Unable to Run Flow: " + $FlowName + " :- " + $_.Exception.Message}
}

Function TS-GetFlowRunTasks
{
  try
 {
  $PageSize = 100
  $PageNumber = 1
  $done = 'FALSE'

  While ($done -eq 'FALSE')
   { 
    $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/tasks/runFlow?pageSize=$PageSize`&pageNumber=$PageNumber -Headers $headers -Method Get
    $totalAvailable = $response.tsResponse.pagination.totalAvailable

    If ($PageSize*$PageNumber -gt $totalAvailable) { $done = 'TRUE'}

    $PageNumber += 1

    ForEach ($detail in $response.tsResponse.tasks.task)
     {
       $Flow = [pscustomobject]@{
       Priority = $detail.flowRun.priority; 
       ConsecutiveFailedCount = $detail.flowRun.consecutiveFailedCount; 
       Type  = $detail.flowRun.type; 
       ScheduleName=$detail.flowRun.schedule.name; 
       ScheduleState=$detail.flowRun.schedule.state;
       SchedulePriority=$detail.flowRun.schedule.priority; 
       ScheduleCreatedAt=$detail.flowRun.schedule.createdAt;
       ScheduleUpdatedAt=$detail.flowRun.schedule.updatedAt;
       ScheduleType=$detail.flowRun.schedule.type;
       ScheduleFrequency=$detail.flowRun.schedule.frequency;
       ScheduleNextRunAt=$detail.flowRun.schedule.nextRunAt;
       ScheduleID=$detail.flowRun.ID;
       FlowID=$detail.flowRun.flow.ID;
       }
      $Flow
     }
   }
 }
 catch {"Unable to Get Flows Run Tasks for Site :- " + $_.Exception.Message}
}


Function TS-GetFlowRunTask
{

 param(
  [string[]] $ScheduleName = "",
  [string[]] $ScheduleID = ""
  )

  try
 {
 if ($ScheduleID -ne '') {$ScheduleID} else {$ScheduleID = TS-GetFlowTaskDetails -Name $ScheduleName}
 $scheduleID

  $response = Invoke-RestMethod -Uri ${protocol}://$server/api/$api_ver/sites/$siteID/tasks/runFlow/$ScheduleID -Headers $headers -Method Get
#  $response.tsResponse.task.flowrun

    ForEach ($detail in $response.tsResponse.task.flowrun)
     {
       $Flow = [pscustomobject]@{
       Priority = $detail.priority; 
       ConsecutiveFailedCount = $detail.consecutiveFailedCount; 
       Type  = $detail.type; 
       ScheduleName=$detail.schedule.name; 
       ScheduleState=$detail.schedule.state;
       SchedulePriority=$detail.schedule.priority; 
       ScheduleCreatedAt=$detail.schedule.createdAt;
       ScheduleUpdatedAt=$detail.schedule.updatedAt;
       ScheduleType=$detail.schedule.type;
       ScheduleFrequency=$detail.schedule.frequency;
       ScheduleNextRunAt=$detail.schedule.nextRunAt;
       FlowRunID=$detail.ID;
       FlowID=$detail.flow.ID;
       }
      $Flow
     }
 
 }
 catch {"Unable to Get Flows Run Tasks for Site :- " + $_.Exception.Message}
}





 
    ## Sign in / Out
    Export-ModuleMember -Function TS-SignIn
    Export-ModuleMember -Function TS-SignOut

    ## Projects Management
    Export-ModuleMember -Function TS-QueryProjects
    Export-ModuleMember -Function TS-DeleteProject
    Export-ModuleMember -Function TS-CreateProject
    Export-ModuleMember -Function TS-UpdateProject

    ## Sites Management
    Export-ModuleMember -Function TS-QuerySites
    Export-ModuleMember -Function TS-QuerySite
    Export-ModuleMember -Function TS-UpdateSite
    Export-ModuleMember -Function TS-CreateSite
    Export-ModuleMember -Function TS-SwitchSite
    Export-ModuleMember -Function TS-DeleteSite

    ## Groups Management
    Export-ModuleMember -Function TS-CreateGroup
    Export-ModuleMember -Function TS-DeleteGroup
    Export-ModuleMember -Function TS-QueryGroups
    Export-ModuleMember -Function TS-UpdateGroup

    ## Users Management
    Export-ModuleMember -Function TS-GetUsersOnSite
    Export-ModuleMember -Function TS-AddUserToGroup
    Export-ModuleMember -Function TS-RemoveUserFromGroup
    Export-ModuleMember -Function TS-RemoveUserFromSite
    Export-ModuleMember -Function TS-GetUsersInGroup
    Export-ModuleMember -Function TS-QueryUser
    Export-ModuleMember -Function TS-AddUserToSite
    Export-ModuleMember -Function TS-UpdateUser

    ## Schedules and Extracts Management
    Export-ModuleMember -Function TS-QuerySchedules
    Export-ModuleMember -Function TS-QueryExtractRefreshTasksForSchedule
    Export-ModuleMember -Function TS-UpdateSchedule
    Export-ModuleMember -Function TS-CreateSchedule
    Export-ModuleMember -Function TS-DeleteSchedule
    Export-ModuleMember -Function TS-RunExtractRefreshTask
    Export-ModuleMember -Function TS-GetExtractRefreshTasks
    Export-ModuleMember -Function TS-GetExtractRefreshTask

    Export-ModuleMember -Function TS-AddDataSourceToSchedule
    Export-ModuleMember -Function TS-AddWorkbookToSchedule
    Export-ModuleMember -Function TS-QueryJobs
    Export-ModuleMember -Function TS-QueryJob
    Export-ModuleMember -Function TS-CancelJob

    ## Workbook and Views Management
    Export-ModuleMember -Function TS-QueryViewsForSite
    Export-ModuleMember -Function TS-QueryWorkbooksForUser
    Export-ModuleMember -Function TS-QueryWorkbooksForSite
    Export-ModuleMember -Function TS-QueryViewsForWorkbook
    Export-ModuleMember -Function TS-QueryWorkbook
    Export-ModuleMember -Function TS-UpdateWorkbook
    Export-ModuleMember -Function TS-DeleteWorkbook
    Export-ModuleMember -Function TS-AddTagsToWorkbook
    Export-ModuleMember -Function TS-DeleteTagFromWorkbook
    Export-ModuleMember -Function TS-QueryWorkbookConnections
    Export-ModuleMember -Function TS-UpdateWorkbookConnection
    Export-ModuleMember -Function TS-UpdateWorkbookNow

    ## DataSources Management
    Export-ModuleMember -Function TS-QueryDataSources
    Export-ModuleMember -Function TS-QueryDataSource
    Export-ModuleMember -Function TS-QueryDataSourceConnections

    Export-ModuleMember -Function TS-DeleteDataSource
    Export-ModuleMember -Function TS-UpdateDataSource
    Export-ModuleMember -Function TS-UpdateDataSourceConnection
    Export-ModuleMember -Function TS-AddTagsToDataSource
    Export-ModuleMember -Function TS-DeleteTagFromDataSource
    Export-ModuleMember -Function TS-AddTagsToView
    Export-ModuleMember -Function TS-DeleteTagFromView
    Export-ModuleMember -Function TS-UpdateDataSourceNow



    ## Favorites Management
    Export-ModuleMember -Function TS-AddWorkbookToFavorites
    Export-ModuleMember -Function TS-AddViewToFavorites
    Export-ModuleMember -Function TS-DeleteWorkbookFromFavorites
    Export-ModuleMember -Function TS-DeleteViewFromFavorites
    Export-ModuleMember -Function TS-AddDataSourceToFavorites
    Export-ModuleMember -Function TS-AddProjectToFavorites
    Export-ModuleMember -Function TS-DeleteDataSourceFromFavorites
    Export-ModuleMember -Function TS-DeleteProjectFromFavorites

    ## Permissions Management
    Export-ModuleMember -Function TS-UpdateProjectPermissions
    Export-ModuleMember -Function TS-QueryProjectPermissions

    Export-ModuleMember -Function TS-QueryWorkbookPermissions
    Export-ModuleMember -Function TS-UpdateWorkbookPermissions

    Export-ModuleMember -Function TS-QueryDataSourcePermissions
    Export-ModuleMember -Function TS-UpdateDataSourcePermissions

    Export-ModuleMember -Function TS-QueryViewPermissions
    Export-ModuleMember -Function TS-UpdateViewPermissions
    

    # Publishing & Downloading
    Export-ModuleMember -Function TS-PublishDataSource
    Export-ModuleMember -Function TS-PublishWorkbook

    Export-ModuleMember -Function TS-DownloadDataSource
    Export-ModuleMember -Function TS-DownloadWorkbook

    Export-ModuleMember -Function TS-QueryWorkbookPreviewImage
    Export-ModuleMember -Function TS-QueryViewPreviewImage
    Export-ModuleMember -Function TS-QueryViewDownload


    # Workbook and DataSource Revisions 
    Export-ModuleMember -Function TS-GetDataSourceRevisions
    Export-ModuleMember -Function TS-GetWorkbookRevisions
    Export-ModuleMember -Function TS-RemoveWorkbookRevision
    Export-ModuleMember -Function TS-RemoveDataSourceRevision
    Export-ModuleMember -Function TS-DownloadDataSourceRevision
    Export-ModuleMember -Function TS-DownloadWorkbookRevision


    # Subscriptions
    Export-ModuleMember -Function TS-CreateSubscription
    Export-ModuleMember -Function TS-QuerySubscriptions
    Export-ModuleMember -Function TS-UpdateSubscription
    Export-ModuleMember -Function TS-DeleteSubscription

    # Data Driven Alerts
    Export-ModuleMember -Function TS-AddUserToDataDrivenAlert
    Export-ModuleMember -Function TS-DeleteUserFromDataDrivenAlert
    Export-ModuleMember -Function TS-QueryDataDrivenAlerts
    Export-ModuleMember -Function TS-UpdateDataDrivenAlert
    Export-ModuleMember -Function TS-DeleteDataDrivenAlert
    Export-ModuleMember -Function TS-QueryDataDrivenAlertDetails


    # Flows Management

    Export-ModuleMember -Function TS-QueryFlowsForSite
    Export-ModuleMember -Function TS-QueryFlow
    Export-ModuleMember -Function TS-RunFlowNow
    Export-ModuleMember -Function TS-GetFlowRunTask
    Export-ModuleMember -Function TS-GetFlowRunTasks
    Export-ModuleMember -Function TS-PublishFlow





