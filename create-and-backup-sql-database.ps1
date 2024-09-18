# Prompt user for input
$resourceGroupName = Read-Host "Enter the name of the resource group"
$location = Read-Host "Enter the Azure region (e.g., EastUS)"
$serverName = Read-Host "Enter a unique SQL server name"
$adminLogin = Read-Host "Enter the SQL admin username"
$adminPassword = Read-Host "Enter the SQL admin password" -AsSecureString
$databaseName = Read-Host "Enter the SQL database name"
$automationAccountName = Read-Host "Enter the Automation account name"
$storageAccountName = Read-Host "Enter the storage account name"
$containerName = Read-Host "Enter the container name for backups"

# Check if Resource Group exists
$resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if (-not $resourceGroup) {
    # Create Resource Group if it doesn't exist
    Write-Host "Resource group doesn't exist. Creating resource group..."
    New-AzResourceGroup -Name $resourceGroupName -Location $location
} else {
    Write-Host "Resource group already exists."
}

# Check if SQL Server exists
$server = Get-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $serverName -ErrorAction SilentlyContinue
if (-not $server) {
    # Create SQL Server if it doesn't exist
    Write-Host "SQL server doesn't exist. Creating SQL server..."
    New-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $serverName `
        -Location $location -SqlAdministratorCredentials (New-Object PSCredential($adminLogin, $adminPassword))
} else {
    Write-Host "SQL server already exists."
}

# Check if SQL Database exists
$database = Get-AzSqlDatabase -ResourceGroupName $resourceGroupName -ServerName $serverName -DatabaseName $databaseName -ErrorAction SilentlyContinue
if (-not $database) {
    # Create SQL Database (Cheapest Basic Tier) if it doesn't exist
    Write-Host "SQL Database doesn't exist. Creating SQL database..."
    New-AzSqlDatabase -ResourceGroupName $resourceGroupName -ServerName $serverName `
        -DatabaseName $databaseName -RequestedServiceObjectiveName "Basic"
} else {
    Write-Host "SQL database already exists."
}

# Output connection string
Write-Host "Database created successfully (if not already existing). Connection String:"
Write-Host "Server=tcp:$serverName.database.windows.net,1433;Initial Catalog=$databaseName;Persist Security Info=False;User ID=$adminLogin;Password=********;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

# Check if Automation Account exists
$automationAccount = Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -Name $automationAccountName -ErrorAction SilentlyContinue
if (-not $automationAccount) {
    # Create Automation Account if it doesn't exist
    Write-Host "Automation account doesn't exist. Creating automation account..."
    New-AzAutomationAccount -ResourceGroupName $resourceGroupName -Name $automationAccountName -Location $location
} else {
    Write-Host "Automation account already exists."
}

# Check if Storage Account exists
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -ErrorAction SilentlyContinue
if (-not $storageAccount) {
    # Create Storage Account if it doesn't exist
    Write-Host "Storage account doesn't exist. Creating storage account..."
    New-AzStorageAccount -ResourceGroupName $resourceGroupName -AccountName $storageAccountName -Location $location -SkuName Standard_LRS
} else {
    Write-Host "Storage account already exists."
}

# Check if Storage Container exists
$storageContext = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName).Context
$container = Get-AzStorageContainer -Context $storageContext -Name $containerName -ErrorAction SilentlyContinue
if (-not $container) {
    # Create Storage Container if it doesn't exist
    Write-Host "Storage container doesn't exist. Creating storage container..."
    New-AzStorageContainer -Name $containerName -Context $storageContext
} else {
    Write-Host "Storage container already exists."
}

# Check if Runbook exists
$runbookName = "AutomateAzureSqlBackup"
$runbook = Get-AzAutomationRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name $runbookName -ErrorAction SilentlyContinue
if (-not $runbook) {
    # Create Runbook if it doesn't exist
    Write-Host "Runbook doesn't exist. Creating runbook for backup automation..."
    $runbookScript = @"
param (
    [string]`$resourceGroupName,
    [string]`$serverName,
    [string]`$databaseName,
    [string]`$storageAccountName,
    [string]`$containerName
)

`$exportBacpacUri = "https://`$storageAccountName.blob.core.windows.net/`$containerName/`$databaseName-`$(Get-Date -Format "yyyyMMdd-HHmmss").bacpac"

Export-AzSqlDatabase -ResourceGroupName `$$resourceGroupName -ServerName `$$serverName `
    -DatabaseName `$$databaseName -StorageUri `$$exportBacpacUri `
    -AdministratorLogin $adminLogin -AdministratorLoginPassword (ConvertTo-SecureString $adminPassword -AsPlainText -Force)

Write-Output "Backup completed. BAC file stored at: `$$exportBacpacUri"
"@

    # Save runbook script to file and import it into Azure Automation
    $runbookPath = "AzureSqlBackup.ps1"
    Set-Content -Path $runbookPath -Value $runbookScript
    Import-AzAutomationRunbook -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name $runbookName -Type PowerShell -Path $runbookPath
} else {
    Write-Host "Runbook already exists."
}

# Check if schedule exists
$scheduleName = "DailyBackup"
$schedule = Get-AzAutomationSchedule -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name $scheduleName -ErrorAction SilentlyContinue
if (-not $schedule) {
    # Create a daily schedule if it doesn't exist
    Write-Host "Schedule doesn't exist. Creating daily schedule for 2 AM..."
    $automationSchedule = New-AzAutomationSchedule -AutomationAccountName $automationAccountName -ResourceGroupName $resourceGroupName -Name $scheduleName -StartTime (Get-Date).Date.AddDays(1).AddHours(2) -DayInterval 1

    # Link the Runbook with the schedule
    Register-AzAutomationScheduledRunbook -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -RunbookName $runbookName -ScheduleName $automationSchedule.Name
} else {
    Write-Host "Schedule already exists."
}
