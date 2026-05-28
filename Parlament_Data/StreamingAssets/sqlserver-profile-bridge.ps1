param(
    [Parameter(Mandatory = $true)]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$SettingsPath,
    [Parameter(Mandatory = $true)]
    [string]$CachePath,
    [string]$InputPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Data

function Read-JsonFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    return $content | ConvertFrom-Json
}

function Ensure-Array {
    param($Value)
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Ensure-CollectionDefaults {
    param($Profile)

    $ownedCards = Ensure-Array $Profile.ownedCards
    if ($ownedCards.Count -eq 0) {
        $ownedCards = @(1,2,3,4,5,6,7,8)
    }

    $selectedDeck = Ensure-Array $Profile.selectedDeck
    if ($selectedDeck.Count -eq 0) {
        $selectedDeck = @($ownedCards)
    }

    $Profile.ownedCards = $ownedCards
    $Profile.selectedDeck = $selectedDeck
}

function Sanitize-SelectedDeck {
    param($Profile)

    $owned = New-Object 'System.Collections.Generic.List[int]'
    foreach ($cardId in (Ensure-Array $Profile.ownedCards | Sort-Object -Unique)) {
        [void]$owned.Add([int]$cardId)
    }

    $deck = New-Object 'System.Collections.Generic.List[int]'
    foreach ($cardId in (Ensure-Array $Profile.selectedDeck | Select-Object -Unique)) {
        $value = [int]$cardId
        if ($owned.Contains($value) -and $deck.Count -lt 20) {
            [void]$deck.Add($value)
        }
    }

    foreach ($cardId in $owned) {
        if ($deck.Count -ge 3) {
            break
        }

        if (-not $deck.Contains($cardId)) {
            [void]$deck.Add($cardId)
        }
    }

    $Profile.ownedCards = @($owned)
    $Profile.selectedDeck = @($deck)
}

function New-ProfileObject {
    param(
        [string]$PlayerId,
        [string]$Nickname,
        [int]$Level,
        [int]$Experience,
        [int]$Coins,
        [string]$Rank,
        [string]$Avatar,
        [int[]]$OwnedCards,
        [int[]]$SelectedDeck,
        $Statistics
    )

    return [pscustomobject]@{
        playerId = $PlayerId
        nickname = $Nickname
        level = $Level
        experience = $Experience
        coins = $Coins
        ownedCards = @($OwnedCards)
        selectedDeck = @($SelectedDeck)
        statistics = [pscustomobject]@{
            totalMatches = [int]$Statistics.totalMatches
            wins = [int]$Statistics.wins
            losses = [int]$Statistics.losses
            onlineMatches = [int]$Statistics.onlineMatches
            offlineMatches = [int]$Statistics.offlineMatches
            cardsPlayed = [int]$Statistics.cardsPlayed
            turnsPlayed = [int]$Statistics.turnsPlayed
        }
        rank = $Rank
        avatar = $Avatar
    }
}

function Open-Connection {
    param([string]$ConnectionString)
    $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $connection.Open()
    return $connection
}

function New-Command {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Sql,
        [System.Data.SqlClient.SqlTransaction]$Transaction = $null,
        [hashtable]$Parameters = $null
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    if ($null -ne $Transaction) {
        $command.Transaction = $Transaction
    }

    if ($null -ne $Parameters) {
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($null -eq $value) {
                $value = [DBNull]::Value
            }

            [void]$command.Parameters.AddWithValue($key, $value)
        }
    }

    return $command
}

function Invoke-ScalarValue {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Sql,
        [System.Data.SqlClient.SqlTransaction]$Transaction = $null,
        [hashtable]$Parameters = $null
    )

    $command = New-Command -Connection $Connection -Sql $Sql -Transaction $Transaction -Parameters $Parameters
    try {
        return $command.ExecuteScalar()
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-NonQuerySql {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Sql,
        [System.Data.SqlClient.SqlTransaction]$Transaction = $null,
        [hashtable]$Parameters = $null
    )

    $command = New-Command -Connection $Connection -Sql $Sql -Transaction $Transaction -Parameters $Parameters
    try {
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-ReaderRows {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Sql,
        [hashtable]$Parameters = $null
    )

    $rows = @()
    $command = New-Command -Connection $Connection -Sql $Sql -Parameters $Parameters
    try {
        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $row = @{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $row[$reader.GetName($i)] = $reader.GetValue($i)
                }
                $rows += [pscustomobject]$row
            }
        }
        finally {
            $reader.Close()
        }
    }
    finally {
        $command.Dispose()
    }

    return $rows
}

function Ensure-Schema {
    param([System.Data.SqlClient.SqlConnection]$Connection)

    $sql = @"
IF OBJECT_ID(N'dbo.players', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.players (
        id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        nickname NVARCHAR(64) NOT NULL UNIQUE,
        rank_name NVARCHAR(32) NOT NULL CONSTRAINT DF_players_rank_name DEFAULT N'Bronze',
        avatar NVARCHAR(64) NOT NULL CONSTRAINT DF_players_avatar DEFAULT N'default',
        level INT NOT NULL CONSTRAINT DF_players_level DEFAULT 1,
        experience INT NOT NULL CONSTRAINT DF_players_experience DEFAULT 0,
        coins INT NOT NULL CONSTRAINT DF_players_coins DEFAULT 500,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_players_created_at DEFAULT SYSUTCDATETIME(),
        updated_at DATETIME2 NOT NULL CONSTRAINT DF_players_updated_at DEFAULT SYSUTCDATETIME()
    );
END;

IF OBJECT_ID(N'dbo.player_statistics', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.player_statistics (
        player_id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        total_matches INT NOT NULL CONSTRAINT DF_player_statistics_total_matches DEFAULT 0,
        wins INT NOT NULL CONSTRAINT DF_player_statistics_wins DEFAULT 0,
        losses INT NOT NULL CONSTRAINT DF_player_statistics_losses DEFAULT 0,
        online_matches INT NOT NULL CONSTRAINT DF_player_statistics_online_matches DEFAULT 0,
        offline_matches INT NOT NULL CONSTRAINT DF_player_statistics_offline_matches DEFAULT 0,
        cards_played INT NOT NULL CONSTRAINT DF_player_statistics_cards_played DEFAULT 0,
        turns_played INT NOT NULL CONSTRAINT DF_player_statistics_turns_played DEFAULT 0,
        CONSTRAINT FK_player_statistics_players FOREIGN KEY (player_id) REFERENCES dbo.players(id) ON DELETE CASCADE
    );
END;

IF OBJECT_ID(N'dbo.cards', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.cards (
        id INT NOT NULL PRIMARY KEY,
        code NVARCHAR(128) NULL UNIQUE,
        name NVARCHAR(128) NOT NULL,
        rarity NVARCHAR(32) NOT NULL,
        card_type NVARCHAR(32) NOT NULL,
        cost INT NOT NULL CONSTRAINT DF_cards_cost DEFAULT 0,
        is_active BIT NOT NULL CONSTRAINT DF_cards_is_active DEFAULT 1
    );
END;

IF OBJECT_ID(N'dbo.player_owned_cards', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.player_owned_cards (
        player_id UNIQUEIDENTIFIER NOT NULL,
        card_id INT NOT NULL,
        obtained_at DATETIME2 NOT NULL CONSTRAINT DF_player_owned_cards_obtained_at DEFAULT SYSUTCDATETIME(),
        source NVARCHAR(32) NULL,
        CONSTRAINT PK_player_owned_cards PRIMARY KEY (player_id, card_id),
        CONSTRAINT FK_player_owned_cards_players FOREIGN KEY (player_id) REFERENCES dbo.players(id) ON DELETE CASCADE,
        CONSTRAINT FK_player_owned_cards_cards FOREIGN KEY (card_id) REFERENCES dbo.cards(id)
    );
END;

IF OBJECT_ID(N'dbo.player_selected_deck', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.player_selected_deck (
        player_id UNIQUEIDENTIFIER NOT NULL,
        slot_index INT NOT NULL,
        card_id INT NOT NULL,
        CONSTRAINT PK_player_selected_deck PRIMARY KEY (player_id, slot_index),
        CONSTRAINT UQ_player_selected_deck_player_card UNIQUE (player_id, card_id),
        CONSTRAINT FK_player_selected_deck_players FOREIGN KEY (player_id) REFERENCES dbo.players(id) ON DELETE CASCADE,
        CONSTRAINT FK_player_selected_deck_cards FOREIGN KEY (card_id) REFERENCES dbo.cards(id)
    );
END;
"@

    Invoke-NonQuerySql -Connection $Connection -Sql $sql
}

function Ensure-Cards {
    param([System.Data.SqlClient.SqlConnection]$Connection)

    $cardsPath = Join-Path (Split-Path -Parent $SettingsPath) "cards.json"
    if (-not (Test-Path $cardsPath)) {
        return
    }

    $cardsRoot = Read-JsonFile $cardsPath
    if ($null -eq $cardsRoot -or $null -eq $cardsRoot.cards) {
        return
    }

    foreach ($card in $cardsRoot.cards) {
        $exists = Invoke-ScalarValue -Connection $Connection -Sql "SELECT 1 FROM dbo.cards WHERE id = @cardId;" -Parameters @{
            "@cardId" = [int]$card.id
        }

        if ($null -ne $exists) {
            continue
        }

        Invoke-NonQuerySql -Connection $Connection -Sql @"
INSERT INTO dbo.cards (id, code, name, rarity, card_type, cost, is_active)
VALUES (@cardId, @code, @name, @rarity, @cardType, @cost, @isActive);
"@ -Parameters @{
            "@cardId" = [int]$card.id
            "@code" = "card_$($card.id)"
            "@name" = [string]$card.name
            "@rarity" = if ([string]::IsNullOrWhiteSpace($card.rarity)) { "Common" } else { [string]$card.rarity }
            "@cardType" = if ([string]::IsNullOrWhiteSpace($card.type)) { "General" } else { [string]$card.type }
            "@cost" = [Math]::Max(0, [int]$card.cost)
            "@isActive" = $true
        }
    }
}

function Get-CachedProfile {
    $cacheRoot = Read-JsonFile $CachePath
    if ($null -eq $cacheRoot) {
        return $null
    }

    if ($null -ne $cacheRoot.profile) {
        return $cacheRoot.profile
    }

    return $cacheRoot
}

function Load-ProfileFromDb {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        $CachedProfile,
        [string]$PreferredNickname
    )

    $playerRow = $null
    if ($null -ne $CachedProfile -and -not [string]::IsNullOrWhiteSpace($CachedProfile.playerId)) {
        $rows = Invoke-ReaderRows -Connection $Connection -Sql @"
SELECT TOP 1 id, nickname, rank_name, avatar, level, experience, coins
FROM dbo.players
WHERE id = @playerId;
"@ -Parameters @{
            "@playerId" = [Guid]$CachedProfile.playerId
        }
        if ($rows.Count -gt 0) {
            $playerRow = $rows[0]
        }
    }

    if ($null -eq $playerRow) {
        $nickname = if ($null -ne $CachedProfile -and -not [string]::IsNullOrWhiteSpace($CachedProfile.nickname)) { [string]$CachedProfile.nickname } else { $PreferredNickname }
        $rows = Invoke-ReaderRows -Connection $Connection -Sql @"
SELECT TOP 1 id, nickname, rank_name, avatar, level, experience, coins
FROM dbo.players
WHERE nickname = @nickname;
"@ -Parameters @{
            "@nickname" = $nickname
        }
        if ($rows.Count -gt 0) {
            $playerRow = $rows[0]
        }
    }

    if ($null -eq $playerRow) {
        return $null
    }

    $statisticsRows = Invoke-ReaderRows -Connection $Connection -Sql @"
SELECT total_matches, wins, losses, online_matches, offline_matches, cards_played, turns_played
FROM dbo.player_statistics
WHERE player_id = @playerId;
"@ -Parameters @{
        "@playerId" = [Guid]$playerRow.id
    }

    $statistics = if ($statisticsRows.Count -gt 0) {
        $statisticsRows[0]
    }
    else {
        [pscustomobject]@{
            total_matches = 0
            wins = 0
            losses = 0
            online_matches = 0
            offline_matches = 0
            cards_played = 0
            turns_played = 0
        }
    }

    $ownedCards = Invoke-ReaderRows -Connection $Connection -Sql @"
SELECT card_id
FROM dbo.player_owned_cards
WHERE player_id = @playerId
ORDER BY card_id;
"@ -Parameters @{
        "@playerId" = [Guid]$playerRow.id
    } | ForEach-Object { [int]$_.card_id }

    $selectedDeck = Invoke-ReaderRows -Connection $Connection -Sql @"
SELECT card_id
FROM dbo.player_selected_deck
WHERE player_id = @playerId
ORDER BY slot_index;
"@ -Parameters @{
        "@playerId" = [Guid]$playerRow.id
    } | ForEach-Object { [int]$_.card_id }

    $profile = New-ProfileObject `
        -PlayerId ([string]$playerRow.id) `
        -Nickname ([string]$playerRow.nickname) `
        -Level ([int]$playerRow.level) `
        -Experience ([int]$playerRow.experience) `
        -Coins ([int]$playerRow.coins) `
        -Rank ([string]$playerRow.rank_name) `
        -Avatar ([string]$playerRow.avatar) `
        -OwnedCards $ownedCards `
        -SelectedDeck $selectedDeck `
        -Statistics @{
            totalMatches = [int]$statistics.total_matches
            wins = [int]$statistics.wins
            losses = [int]$statistics.losses
            onlineMatches = [int]$statistics.online_matches
            offlineMatches = [int]$statistics.offline_matches
            cardsPlayed = [int]$statistics.cards_played
            turnsPlayed = [int]$statistics.turns_played
        }

    Ensure-CollectionDefaults $profile
    Sanitize-SelectedDeck $profile
    return $profile
}

function Save-ProfileToDb {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        $Profile
    )

    if ([string]::IsNullOrWhiteSpace($Profile.playerId)) {
        $Profile.playerId = ([Guid]::NewGuid()).ToString()
    }

    if ([string]::IsNullOrWhiteSpace($Profile.nickname)) {
        $Profile.nickname = "Senator"
    }

    if ([string]::IsNullOrWhiteSpace($Profile.rank)) {
        $Profile.rank = "Bronze"
    }

    if ([string]::IsNullOrWhiteSpace($Profile.avatar)) {
        $Profile.avatar = "default"
    }

    if ($null -eq $Profile.statistics) {
        $Profile | Add-Member -NotePropertyName statistics -NotePropertyValue ([pscustomobject]@{
            totalMatches = 0
            wins = 0
            losses = 0
            onlineMatches = 0
            offlineMatches = 0
            cardsPlayed = 0
            turnsPlayed = 0
        }) -Force
    }

    Ensure-CollectionDefaults $Profile
    Sanitize-SelectedDeck $Profile

    $transaction = $Connection.BeginTransaction()
    try {
        $exists = Invoke-ScalarValue -Connection $Connection -Sql "SELECT 1 FROM dbo.players WHERE id = @playerId;" -Transaction $transaction -Parameters @{
            "@playerId" = [Guid]$Profile.playerId
        }

        if ($null -ne $exists) {
            Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql @"
UPDATE dbo.players
SET nickname = @nickname,
    rank_name = @rankName,
    avatar = @avatar,
    level = @level,
    experience = @experience,
    coins = @coins,
    updated_at = SYSUTCDATETIME()
WHERE id = @playerId;
"@ -Parameters @{
                "@playerId" = [Guid]$Profile.playerId
                "@nickname" = [string]$Profile.nickname
                "@rankName" = [string]$Profile.rank
                "@avatar" = [string]$Profile.avatar
                "@level" = [Math]::Max(1, [int]$Profile.level)
                "@experience" = [Math]::Max(0, [int]$Profile.experience)
                "@coins" = [Math]::Max(0, [int]$Profile.coins)
            }
        }
        else {
            Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql @"
INSERT INTO dbo.players (id, nickname, rank_name, avatar, level, experience, coins)
VALUES (@playerId, @nickname, @rankName, @avatar, @level, @experience, @coins);
"@ -Parameters @{
                "@playerId" = [Guid]$Profile.playerId
                "@nickname" = [string]$Profile.nickname
                "@rankName" = [string]$Profile.rank
                "@avatar" = [string]$Profile.avatar
                "@level" = [Math]::Max(1, [int]$Profile.level)
                "@experience" = [Math]::Max(0, [int]$Profile.experience)
                "@coins" = [Math]::Max(0, [int]$Profile.coins)
            }
        }

        $statsExists = Invoke-ScalarValue -Connection $Connection -Sql "SELECT 1 FROM dbo.player_statistics WHERE player_id = @playerId;" -Transaction $transaction -Parameters @{
            "@playerId" = [Guid]$Profile.playerId
        }

        if ($null -ne $statsExists) {
            Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql @"
UPDATE dbo.player_statistics
SET total_matches = @totalMatches,
    wins = @wins,
    losses = @losses,
    online_matches = @onlineMatches,
    offline_matches = @offlineMatches,
    cards_played = @cardsPlayed,
    turns_played = @turnsPlayed
WHERE player_id = @playerId;
"@ -Parameters @{
                "@playerId" = [Guid]$Profile.playerId
                "@totalMatches" = [Math]::Max(0, [int]$Profile.statistics.totalMatches)
                "@wins" = [Math]::Max(0, [int]$Profile.statistics.wins)
                "@losses" = [Math]::Max(0, [int]$Profile.statistics.losses)
                "@onlineMatches" = [Math]::Max(0, [int]$Profile.statistics.onlineMatches)
                "@offlineMatches" = [Math]::Max(0, [int]$Profile.statistics.offlineMatches)
                "@cardsPlayed" = [Math]::Max(0, [int]$Profile.statistics.cardsPlayed)
                "@turnsPlayed" = [Math]::Max(0, [int]$Profile.statistics.turnsPlayed)
            }
        }
        else {
            Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql @"
INSERT INTO dbo.player_statistics (player_id, total_matches, wins, losses, online_matches, offline_matches, cards_played, turns_played)
VALUES (@playerId, @totalMatches, @wins, @losses, @onlineMatches, @offlineMatches, @cardsPlayed, @turnsPlayed);
"@ -Parameters @{
                "@playerId" = [Guid]$Profile.playerId
                "@totalMatches" = [Math]::Max(0, [int]$Profile.statistics.totalMatches)
                "@wins" = [Math]::Max(0, [int]$Profile.statistics.wins)
                "@losses" = [Math]::Max(0, [int]$Profile.statistics.losses)
                "@onlineMatches" = [Math]::Max(0, [int]$Profile.statistics.onlineMatches)
                "@offlineMatches" = [Math]::Max(0, [int]$Profile.statistics.offlineMatches)
                "@cardsPlayed" = [Math]::Max(0, [int]$Profile.statistics.cardsPlayed)
                "@turnsPlayed" = [Math]::Max(0, [int]$Profile.statistics.turnsPlayed)
            }
        }

        Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql "DELETE FROM dbo.player_owned_cards WHERE player_id = @playerId;" -Parameters @{
            "@playerId" = [Guid]$Profile.playerId
        }

        foreach ($cardId in (Ensure-Array $Profile.ownedCards | Sort-Object -Unique)) {
            Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql @"
INSERT INTO dbo.player_owned_cards (player_id, card_id, source)
VALUES (@playerId, @cardId, @source);
"@ -Parameters @{
                "@playerId" = [Guid]$Profile.playerId
                "@cardId" = [int]$cardId
                "@source" = "unity"
            }
        }

        Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql "DELETE FROM dbo.player_selected_deck WHERE player_id = @playerId;" -Parameters @{
            "@playerId" = [Guid]$Profile.playerId
        }

        $slotIndex = 0
        foreach ($cardId in (Ensure-Array $Profile.selectedDeck)) {
            Invoke-NonQuerySql -Connection $Connection -Transaction $transaction -Sql @"
INSERT INTO dbo.player_selected_deck (player_id, slot_index, card_id)
VALUES (@playerId, @slotIndex, @cardId);
"@ -Parameters @{
                "@playerId" = [Guid]$Profile.playerId
                "@slotIndex" = $slotIndex
                "@cardId" = [int]$cardId
            }
            $slotIndex++
        }

        $transaction.Commit()
    }
    catch {
        $transaction.Rollback()
        throw
    }

    return Load-ProfileFromDb -Connection $Connection -CachedProfile $Profile -PreferredNickname ([string]$Profile.nickname)
}

try {
    $settings = Read-JsonFile $SettingsPath
    if ($null -eq $settings -or -not $settings.enabled -or [string]::IsNullOrWhiteSpace($settings.connectionString)) {
        exit 0
    }

    $connection = Open-Connection $settings.connectionString
    try {
        Ensure-Schema $connection
        Ensure-Cards $connection

        if ($Mode -eq "Load") {
            $cachedProfile = Get-CachedProfile
            $profile = Load-ProfileFromDb -Connection $connection -CachedProfile $cachedProfile -PreferredNickname ([string]$settings.preferredNickname)
            if ($null -ne $profile) {
                $profile | ConvertTo-Json -Depth 6 -Compress | Write-Output
            }
        }
        elseif ($Mode -eq "Save") {
            $profile = Read-JsonFile $InputPath
            if ($null -eq $profile) {
                throw "Input profile JSON not found."
            }

            $savedProfile = Save-ProfileToDb -Connection $connection -Profile $profile
            $savedProfile | ConvertTo-Json -Depth 6 -Compress | Write-Output
        }
        else {
            throw "Unsupported mode: $Mode"
        }
    }
    finally {
        $connection.Dispose()
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
