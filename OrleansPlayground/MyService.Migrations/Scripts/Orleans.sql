﻿-- SHARED source: https://github.com/dotnet/orleans/blob/main/src/AdoNet/Shared/SQLServer-Main.sql

/*
Implementation notes:

1) The general idea is that data is read and written through Orleans specific queries.
   Orleans operates on column names and types when reading and on parameter names and types when writing.

2) The implementations *must* preserve input and output names and types. Orleans uses these parameters to reads query results by name and type.
   Vendor and deployment specific tuning is allowed and contributions are encouraged as long as the interface contract
   is maintained.

3) The implementation across vendor specific scripts *should* preserve the constraint names. This simplifies troubleshooting
   by virtue of uniform naming across concrete implementations.

5) ETag for Orleans is an opaque column that represents a unique version. The type of its actual implementation
   is not important as long as it represents a unique version. In this implementation we use integers for versioning

6) For the sake of being explicit and removing ambiguity, Orleans expects some queries to return either TRUE as >0 value
   or FALSE as =0 value. That is, affected rows or such does not matter. If an error is raised or an exception is thrown
   the query *must* ensure the entire transaction is rolled back and may either return FALSE or propagate the exception.
   Orleans handles exception as a failure and will retry.

7) The implementation follows the Extended Orleans membership protocol. For more information, see at:
        https://learn.microsoft.com/dotnet/orleans/implementation/cluster-management
        https://github.com/dotnet/orleans/blob/main/src/Orleans.Core/SystemTargetInterfaces/IMembershipTable.cs
*/

-- These settings improves throughput of the database by reducing locking by better separating readers from writers.
-- SQL Server 2012 and newer can refer to itself as CURRENT. Older ones need a workaround.
DECLARE @current NVARCHAR(256);
DECLARE @snapshotSettings NVARCHAR(612);

SELECT @current = N'[' + (SELECT DB_NAME()) + N']';
SET @snapshotSettings = N'ALTER DATABASE ' + @current + N' SET READ_COMMITTED_SNAPSHOT ON; ALTER DATABASE ' + @current + N' SET ALLOW_SNAPSHOT_ISOLATION ON;';

EXECUTE sp_executesql @snapshotSettings;

-- This table defines Orleans operational queries. Orleans uses these to manage its operations,
-- these are the only queries Orleans issues to the database.
-- These can be redefined (e.g. to provide non-destructive updates) provided the stated interface principles hold.
IF OBJECT_ID(N'[OrleansQuery]', 'U') IS NULL
CREATE TABLE OrleansQuery
(
	QueryKey VARCHAR(64) NOT NULL,
	QueryText VARCHAR(8000) NOT NULL,

	CONSTRAINT OrleansQuery_Key PRIMARY KEY(QueryKey)
);

-- --------------------------------------------------------------------------------------------------------------------
-- PERSISTENCE source: https://github.com/dotnet/orleans/blob/main/src/AdoNet/Orleans.Persistence.AdoNet/SQLServer-Persistence.sql

-- The design criteria for this table are:
--
-- 1. It can contain arbitrary content serialized as binary, XML or JSON. These formats
-- are supported to allow one to take advantage of in-storage processing capabilities for
-- these types if required. This should not incur extra cost on storage.
--
-- 2. The table design should scale with the idea of tens or hundreds (or even more) types
-- of grains that may operate with even hundreds of thousands of grain IDs within each
-- type of a grain.
--
-- 3. The table and its associated operations should remain stable. There should not be
-- structural reason for unexpected delays in operations. It should be possible to also
-- insert data reasonably fast without resource contention.
--
-- 4. For reasons in 2. and 3., the index should be as narrow as possible so it fits well in
-- memory and should it require maintenance, isn't resource intensive. For this
-- reason the index is narrow by design (ideally non-clustered). Currently the entity
-- is recognized in the storage by the grain type and its ID, which are unique in Orleans silo.
-- The ID is the grain ID bytes (if string type UTF-8 bytes) and possible extension key as UTF-8
-- bytes concatenated with the ID and then hashed.
--
-- Reason for hashing: Database engines usually limit the length of the column sizes, which
-- would artificially limit the length of IDs or types. Even when within limitations, the
-- index would be thick and consume more memory.
--
-- In the current setup the ID and the type are hashed into two INT type instances, which
-- are made a compound index. When there are no collisions, the index can quickly locate
-- the unique row. Along with the hashed index values, the NVARCHAR(nnn) values are also
-- stored and they are used to prune hash collisions down to only one result row.
--
-- 5. The design leads to duplication in the storage. It is reasonable to assume there will
-- a low number of services with a given service ID operational at any given time. Or that
-- compared to the number of grain IDs, there are a fairly low number of different types of
-- grain. The catch is that were these data separated to another table, it would make INSERT
-- and UPDATE operations complicated and would require joins, temporary variables and additional
-- indexes or some combinations of them to make it work. It looks like fitting strategy
-- could be to use table compression.
--
-- 6. For the aforementioned reasons, grain state DELETE will set NULL to the data fields
-- and updates the Version number normally. This should alleviate the need for index or
-- statistics maintenance with the loss of some bytes of storage space. The table can be scrubbed
-- in a separate maintenance operation.
--
-- 7. In the storage operations queries the columns need to be in the exact same order
-- since the storage table operations support optionally streaming.
IF OBJECT_ID(N'[OrleansStorage]', 'U') IS NULL
CREATE TABLE OrleansStorage
(
    -- These are for the book keeping. Orleans calculates
    -- these hashes (see RelationalStorageProvide implementation),
    -- which are signed 32 bit integers mapped to the *Hash fields.
    -- The mapping is done in the code. The
    -- *String columns contain the corresponding clear name fields.
    --
    -- If there are duplicates, they are resolved by using GrainIdN0,
    -- GrainIdN1, GrainIdExtensionString and GrainTypeString fields.
    -- It is assumed these would be rarely needed.
    GrainIdHash                INT NOT NULL,
    GrainIdN0                BIGINT NOT NULL,
    GrainIdN1                BIGINT NOT NULL,
    GrainTypeHash            INT NOT NULL,
    GrainTypeString            NVARCHAR(512) NOT NULL,
    GrainIdExtensionString    NVARCHAR(512) NULL,
    ServiceId                NVARCHAR(150) NOT NULL,

    -- Payload
    PayloadBinary    VARBINARY(MAX) NULL,

    -- Informational field, no other use.
    ModifiedOn DATETIME2(3) NOT NULL,

    -- The version of the stored payload.
    Version INT NULL

    -- The following would in principle be the primary key, but it would be too thick
    -- to be indexed, so the values are hashed and only collisions will be solved
    -- by using the fields. That is, after the indexed queries have pinpointed the right
    -- rows down to [0, n] relevant ones, n being the number of collided value pairs.
);

IF NOT EXISTS(SELECT * FROM sys.indexes WHERE name = 'IX_OrleansStorage' AND object_id = OBJECT_ID('OrleansStorage'))
BEGIN
	CREATE NONCLUSTERED INDEX IX_OrleansStorage ON OrleansStorage(GrainIdHash, GrainTypeHash);
END

-- This ensures lock escalation will not lock the whole table, which can potentially be enormous.
-- See more information at https://www.littlekendra.com/2016/02/04/why-rowlock-hints-can-make-queries-slower-and-blocking-worse-in-sql-server/.
ALTER TABLE OrleansStorage SET(LOCK_ESCALATION = DISABLE);

-- A feature with ID is compression. If it is supported, it is used for OrleansStorage table. This is an Enterprise feature.
-- This consumes more processor cycles, but should save on space on GrainIdString, GrainTypeString and ServiceId, which
-- contain mainly the same values. Also the payloads will be compressed.
IF EXISTS (SELECT 1 FROM sys.dm_db_persisted_sku_features WHERE feature_id = 100)
BEGIN
    ALTER TABLE OrleansStorage REBUILD PARTITION = ALL WITH(DATA_COMPRESSION = PAGE);
END

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
    'WriteToStorageKey',
    '-- When Orleans is running in normal, non-split state, there will
    -- be only one grain with the given ID and type combination only. This
    -- grain saves states mostly serially if Orleans guarantees are upheld. Even
    -- if not, the updates should work correctly due to version number.
    --
    -- In split brain situations there can be a situation where there are two or more
    -- grains with the given ID and type combination. When they try to INSERT
    -- concurrently, the table needs to be locked pessimistically before one of
    -- the grains gets @GrainStateVersion = 1 in return and the other grains will fail
    -- to update storage. The following arrangement is made to reduce locking in normal operation.
    --
    -- If the version number explicitly returned is still the same, Orleans interprets it so the update did not succeed
    -- and throws an InconsistentStateException.
    --
    -- See further information at https://learn.microsoft.com/dotnet/orleans/grains/grain-persistence.
    BEGIN TRANSACTION;
    SET XACT_ABORT, NOCOUNT ON;

    DECLARE @NewGrainStateVersion AS INT = @GrainStateVersion;


    -- If the @GrainStateVersion is not zero, this branch assumes it exists in this database.
    -- The NULL value is supplied by Orleans when the state is new.
    IF @GrainStateVersion IS NOT NULL
    BEGIN
        UPDATE OrleansStorage
        SET
            PayloadBinary = @PayloadBinary,
            ModifiedOn = GETUTCDATE(),
            Version = Version + 1,
            @NewGrainStateVersion = Version + 1,
            @GrainStateVersion = Version + 1
        WHERE
            GrainIdHash = @GrainIdHash AND @GrainIdHash IS NOT NULL
            AND GrainTypeHash = @GrainTypeHash AND @GrainTypeHash IS NOT NULL
            AND (GrainIdN0 = @GrainIdN0 OR @GrainIdN0 IS NULL)
            AND (GrainIdN1 = @GrainIdN1 OR @GrainIdN1 IS NULL)
            AND (GrainTypeString = @GrainTypeString OR @GrainTypeString IS NULL)
            AND ((@GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString = @GrainIdExtensionString) OR @GrainIdExtensionString IS NULL AND GrainIdExtensionString IS NULL)
            AND ServiceId = @ServiceId AND @ServiceId IS NOT NULL
            AND Version IS NOT NULL AND Version = @GrainStateVersion AND @GrainStateVersion IS NOT NULL
            OPTION(FAST 1, OPTIMIZE FOR(@GrainIdHash UNKNOWN, @GrainTypeHash UNKNOWN));
    END

    -- The grain state has not been read. The following locks rather pessimistically
    -- to ensure only one INSERT succeeds.
    IF @GrainStateVersion IS NULL
    BEGIN
        INSERT INTO OrleansStorage
        (
            GrainIdHash,
            GrainIdN0,
            GrainIdN1,
            GrainTypeHash,
            GrainTypeString,
            GrainIdExtensionString,
            ServiceId,
            PayloadBinary,
            ModifiedOn,
            Version
        )
        SELECT
            @GrainIdHash,
            @GrainIdN0,
            @GrainIdN1,
            @GrainTypeHash,
            @GrainTypeString,
            @GrainIdExtensionString,
            @ServiceId,
            @PayloadBinary,
            GETUTCDATE(),
            1
         WHERE NOT EXISTS
         (
            -- There should not be any version of this grain state.
            SELECT 1
            FROM OrleansStorage WITH(XLOCK, ROWLOCK, HOLDLOCK, INDEX(IX_OrleansStorage))
            WHERE
                GrainIdHash = @GrainIdHash AND @GrainIdHash IS NOT NULL
                AND GrainTypeHash = @GrainTypeHash AND @GrainTypeHash IS NOT NULL
                AND (GrainIdN0 = @GrainIdN0 OR @GrainIdN0 IS NULL)
                AND (GrainIdN1 = @GrainIdN1 OR @GrainIdN1 IS NULL)
                AND (GrainTypeString = @GrainTypeString OR @GrainTypeString IS NULL)
                AND ((@GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString = @GrainIdExtensionString) OR @GrainIdExtensionString IS NULL AND GrainIdExtensionString IS NULL)
                AND ServiceId = @ServiceId AND @ServiceId IS NOT NULL
         ) OPTION(FAST 1, OPTIMIZE FOR(@GrainIdHash UNKNOWN, @GrainTypeHash UNKNOWN));

        IF @@ROWCOUNT > 0
        BEGIN
            SET @NewGrainStateVersion = 1;
        END
    END

    SELECT @NewGrainStateVersion AS NewGrainStateVersion;
    COMMIT TRANSACTION;'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'WriteToStorageKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
    'ClearStorageKey',
    'BEGIN TRANSACTION;
    SET XACT_ABORT, NOCOUNT ON;
    DECLARE @NewGrainStateVersion AS INT = @GrainStateVersion;
    UPDATE OrleansStorage
    SET
        PayloadBinary = NULL,
        ModifiedOn = GETUTCDATE(),
        Version = Version + 1,
        @NewGrainStateVersion = Version + 1
    WHERE
        GrainIdHash = @GrainIdHash AND @GrainIdHash IS NOT NULL
        AND GrainTypeHash = @GrainTypeHash AND @GrainTypeHash IS NOT NULL
        AND (GrainIdN0 = @GrainIdN0 OR @GrainIdN0 IS NULL)
        AND (GrainIdN1 = @GrainIdN1 OR @GrainIdN1 IS NULL)
        AND (GrainTypeString = @GrainTypeString OR @GrainTypeString IS NULL)
        AND ((@GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString = @GrainIdExtensionString) OR @GrainIdExtensionString IS NULL AND GrainIdExtensionString IS NULL)
        AND ServiceId = @ServiceId AND @ServiceId IS NOT NULL
        AND Version IS NOT NULL AND Version = @GrainStateVersion AND @GrainStateVersion IS NOT NULL
        OPTION(FAST 1, OPTIMIZE FOR(@GrainIdHash UNKNOWN, @GrainTypeHash UNKNOWN));

    SELECT @NewGrainStateVersion;
    COMMIT TRANSACTION;'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'ClearStorageKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
    'ReadFromStorageKey',
    '-- The application code will deserialize the relevant result. Not that the query optimizer
    -- estimates the result of rows based on its knowledge on the index. It does not know there
    -- will be only one row returned. Forcing the optimizer to process the first found row quickly
    -- creates an estimate for a one-row result and makes a difference on multi-million row tables.
    -- Also the optimizer is instructed to always use the same plan via index using the OPTIMIZE
    -- FOR UNKNOWN flags. These hints are only available in SQL Server 2008 and later. They
    -- should guarantee the execution time is robustly basically the same from query-to-query.
    SELECT
        PayloadBinary,
        Version
    FROM
        OrleansStorage
    WHERE
        GrainIdHash = @GrainIdHash AND @GrainIdHash IS NOT NULL
        AND GrainTypeHash = @GrainTypeHash AND @GrainTypeHash IS NOT NULL
        AND (GrainIdN0 = @GrainIdN0 OR @GrainIdN0 IS NULL)
        AND (GrainIdN1 = @GrainIdN1 OR @GrainIdN1 IS NULL)
        AND (GrainTypeString = @GrainTypeString OR @GrainTypeString IS NULL)
        AND ((@GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString IS NOT NULL AND GrainIdExtensionString = @GrainIdExtensionString) OR @GrainIdExtensionString IS NULL AND GrainIdExtensionString IS NULL)
        AND ServiceId = @ServiceId AND @ServiceId IS NOT NULL
        OPTION(FAST 1, OPTIMIZE FOR(@GrainIdHash UNKNOWN, @GrainTypeHash UNKNOWN));'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'ReadFromStorageKey'
);

-- --------------------------------------------------------------------------------------------------------------------
-- REMINDERS source: https://github.com/dotnet/orleans/blob/main/src/AdoNet/Orleans.Reminders.AdoNet/SQLServer-Reminders.sql

-- Orleans Reminders table - https://learn.microsoft.com/dotnet/orleans/grains/timers-and-reminders
IF OBJECT_ID(N'[OrleansRemindersTable]', 'U') IS NULL
CREATE TABLE OrleansRemindersTable
(
	ServiceId NVARCHAR(150) NOT NULL,
	GrainId VARCHAR(150) NOT NULL,
	ReminderName NVARCHAR(150) NOT NULL,
	StartTime DATETIME2(3) NOT NULL,
	Period BIGINT NOT NULL,
	GrainHash INT NOT NULL,
	Version INT NOT NULL,

	CONSTRAINT PK_RemindersTable_ServiceId_GrainId_ReminderName PRIMARY KEY(ServiceId, GrainId, ReminderName)
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'UpsertReminderRowKey',
	'DECLARE @Version AS INT = 0;
	SET XACT_ABORT, NOCOUNT ON;
	BEGIN TRANSACTION;
	UPDATE OrleansRemindersTable WITH(UPDLOCK, ROWLOCK, HOLDLOCK)
	SET
		StartTime = @StartTime,
		Period = @Period,
		GrainHash = @GrainHash,
		@Version = Version = Version + 1
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainId = @GrainId AND @GrainId IS NOT NULL
		AND ReminderName = @ReminderName AND @ReminderName IS NOT NULL;

	INSERT INTO OrleansRemindersTable
	(
		ServiceId,
		GrainId,
		ReminderName,
		StartTime,
		Period,
		GrainHash,
		Version
	)
	SELECT
		@ServiceId,
		@GrainId,
		@ReminderName,
		@StartTime,
		@Period,
		@GrainHash,
		0
	WHERE
		@@ROWCOUNT=0;
	SELECT @Version AS Version;
	COMMIT TRANSACTION;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'UpsertReminderRowKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'ReadReminderRowsKey',
	'SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainId = @GrainId AND @GrainId IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'ReadReminderRowsKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'ReadReminderRowKey',
	'SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainId = @GrainId AND @GrainId IS NOT NULL
		AND ReminderName = @ReminderName AND @ReminderName IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'ReadReminderRowKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'ReadRangeRows1Key',
	'SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainHash > @BeginHash AND @BeginHash IS NOT NULL
		AND GrainHash <= @EndHash AND @EndHash IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'ReadRangeRows1Key'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'ReadRangeRows2Key',
	'SELECT
		GrainId,
		ReminderName,
		StartTime,
		Period,
		Version
	FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND ((GrainHash > @BeginHash AND @BeginHash IS NOT NULL)
		OR (GrainHash <= @EndHash AND @EndHash IS NOT NULL));
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'ReadRangeRows2Key'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'DeleteReminderRowKey',
	'DELETE FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL
		AND GrainId = @GrainId AND @GrainId IS NOT NULL
		AND ReminderName = @ReminderName AND @ReminderName IS NOT NULL
		AND Version = @Version AND @Version IS NOT NULL;
	SELECT @@ROWCOUNT;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'DeleteReminderRowKey'
);    

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'DeleteReminderRowsKey',
	'DELETE FROM OrleansRemindersTable
	WHERE
		ServiceId = @ServiceId AND @ServiceId IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'DeleteReminderRowsKey'
);  

-- --------------------------------------------------------------------------------------------------------------------
-- CLUSTERING source: https://github.com/dotnet/orleans/blob/main/src/AdoNet/Orleans.Clustering.AdoNet/SQLServer-Clustering.sql

-- For each deployment, there will be only one (active) membership version table version column which will be updated periodically.
IF OBJECT_ID(N'[OrleansMembershipVersionTable]', 'U') IS NULL
CREATE TABLE OrleansMembershipVersionTable
(
	DeploymentId NVARCHAR(150) NOT NULL,
	Timestamp DATETIME2(3) NOT NULL DEFAULT GETUTCDATE(),
	Version INT NOT NULL DEFAULT 0,

	CONSTRAINT PK_OrleansMembershipVersionTable_DeploymentId PRIMARY KEY(DeploymentId)
);

-- Every silo instance has a row in the membership table.
IF OBJECT_ID(N'[OrleansMembershipTable]', 'U') IS NULL
CREATE TABLE OrleansMembershipTable
(
	DeploymentId NVARCHAR(150) NOT NULL,
	Address VARCHAR(45) NOT NULL,
	Port INT NOT NULL,
	Generation INT NOT NULL,
	SiloName NVARCHAR(150) NOT NULL,
	HostName NVARCHAR(150) NOT NULL,
	Status INT NOT NULL,
	ProxyPort INT NULL,
	SuspectTimes VARCHAR(8000) NULL,
	StartTime DATETIME2(3) NOT NULL,
	IAmAliveTime DATETIME2(3) NOT NULL,

	CONSTRAINT PK_MembershipTable_DeploymentId PRIMARY KEY(DeploymentId, Address, Port, Generation),
	CONSTRAINT FK_MembershipTable_MembershipVersionTable_DeploymentId FOREIGN KEY (DeploymentId) REFERENCES OrleansMembershipVersionTable (DeploymentId)
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'UpdateIAmAlivetimeKey',
	'-- This is expected to never fail by Orleans, so return value
	-- is not needed nor is it checked.
	SET NOCOUNT ON;
	UPDATE OrleansMembershipTable
	SET
		IAmAliveTime = @IAmAliveTime
	WHERE
		DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
		AND Address = @Address AND @Address IS NOT NULL
		AND Port = @Port AND @Port IS NOT NULL
		AND Generation = @Generation AND @Generation IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'UpdateIAmAlivetimeKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT 
	'InsertMembershipVersionKey',
	'SET NOCOUNT ON;
	INSERT INTO OrleansMembershipVersionTable
	(
		DeploymentId
	)
	SELECT @DeploymentId
	WHERE NOT EXISTS
	(
		SELECT 1
		FROM
			OrleansMembershipVersionTable WITH(HOLDLOCK, XLOCK, ROWLOCK)
		WHERE
			DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
	);
	
	SELECT @@ROWCOUNT;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'InsertMembershipVersionKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'InsertMembershipKey',
	'SET XACT_ABORT, NOCOUNT ON;
	DECLARE @ROWCOUNT AS INT;
	BEGIN TRANSACTION;
	INSERT INTO OrleansMembershipTable
	(
		DeploymentId,
		Address,
		Port,
		Generation,
		SiloName,
		HostName,
		Status,
		ProxyPort,
		StartTime,
		IAmAliveTime
	)
	SELECT
		@DeploymentId,
		@Address,
		@Port,
		@Generation,
		@SiloName,
		@HostName,
		@Status,
		@ProxyPort,
		@StartTime,
		@IAmAliveTime
	WHERE NOT EXISTS
	(
		SELECT 1
		FROM
			OrleansMembershipTable WITH(HOLDLOCK, XLOCK, ROWLOCK)
		WHERE
			DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
			AND Address = @Address AND @Address IS NOT NULL
			AND Port = @Port AND @Port IS NOT NULL
			AND Generation = @Generation AND @Generation IS NOT NULL
	);

	UPDATE OrleansMembershipVersionTable
	SET
		Timestamp = GETUTCDATE(),
		Version = Version + 1
	WHERE
		DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
		AND Version = @Version AND @Version IS NOT NULL
		AND @@ROWCOUNT > 0;
	
	SET @ROWCOUNT = @@ROWCOUNT;
	
	IF @ROWCOUNT = 0
		ROLLBACK TRANSACTION
	ELSE
		COMMIT TRANSACTION
	SELECT @ROWCOUNT;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'InsertMembershipKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'UpdateMembershipKey',
	'SET XACT_ABORT, NOCOUNT ON;
	BEGIN TRANSACTION;
	
	UPDATE OrleansMembershipVersionTable
	SET
		Timestamp = GETUTCDATE(),
		Version = Version + 1
	WHERE
		DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
		AND Version = @Version AND @Version IS NOT NULL;
	
	UPDATE OrleansMembershipTable
	SET
		Status = @Status,
		SuspectTimes = @SuspectTimes,
		IAmAliveTime = @IAmAliveTime
	WHERE
		DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
		AND Address = @Address AND @Address IS NOT NULL
		AND Port = @Port AND @Port IS NOT NULL
		AND Generation = @Generation AND @Generation IS NOT NULL
		AND @@ROWCOUNT > 0;
	
	SELECT @@ROWCOUNT;
	COMMIT TRANSACTION;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'UpdateMembershipKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'GatewaysQueryKey',
	'SELECT
		Address,
		ProxyPort,
		Generation
	FROM
		OrleansMembershipTable
	WHERE
		DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL
		AND Status = @Status AND @Status IS NOT NULL
		AND ProxyPort > 0;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'GatewaysQueryKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'MembershipReadRowKey',
	'SELECT
		v.DeploymentId,
		m.Address,
		m.Port,
		m.Generation,
		m.SiloName,
		m.HostName,
		m.Status,
		m.ProxyPort,
		m.SuspectTimes,
		m.StartTime,
		m.IAmAliveTime,
		v.Version
	FROM
		OrleansMembershipVersionTable v
		-- This ensures the version table will returned even if there is no matching membership row.
		LEFT OUTER JOIN OrleansMembershipTable m ON v.DeploymentId = m.DeploymentId
		AND Address = @Address AND @Address IS NOT NULL
		AND Port = @Port AND @Port IS NOT NULL
		AND Generation = @Generation AND @Generation IS NOT NULL
	WHERE
		v.DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'MembershipReadRowKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'MembershipReadAllKey',
	'SELECT
		v.DeploymentId,
		m.Address,
		m.Port,
		m.Generation,
		m.SiloName,
		m.HostName,
		m.Status,
		m.ProxyPort,
		m.SuspectTimes,
		m.StartTime,
		m.IAmAliveTime,
		v.Version
	FROM
		OrleansMembershipVersionTable v LEFT OUTER JOIN OrleansMembershipTable m
		ON v.DeploymentId = m.DeploymentId
	WHERE
		v.DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'MembershipReadAllKey'
);

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
	'DeleteMembershipTableEntriesKey',
	'DELETE FROM OrleansMembershipTable
	WHERE DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
	DELETE FROM OrleansMembershipVersionTable
	WHERE DeploymentId = @DeploymentId AND @DeploymentId IS NOT NULL;
	'
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'DeleteMembershipTableEntriesKey'
);

-- --------------------------------------------------------------------------------------------------------------------
-- CLUSTERING MIGRATION source: https://github.com/dotnet/orleans/blob/main/src/AdoNet/Orleans.Clustering.AdoNet/Migrations/SQLServer-Clustering-3.7.0.sql

INSERT INTO OrleansQuery(QueryKey, QueryText)
SELECT
    'CleanupDefunctSiloEntriesKey',
    'DELETE FROM OrleansMembershipTable
    WHERE DeploymentId = @DeploymentId
        AND @DeploymentId IS NOT NULL
        AND IAmAliveTime < @IAmAliveTime
        AND Status != 3;
    '
WHERE NOT EXISTS 
( 
    SELECT 1 
    FROM OrleansQuery oqt
    WHERE oqt.[QueryKey] = 'CleanupDefunctSiloEntriesKey'
);