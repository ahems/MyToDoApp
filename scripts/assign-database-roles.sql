-- Create external user if missing
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '{{IDENTITY_NAME}}')
BEGIN
    PRINT 'Creating external user [{{IDENTITY_NAME}}]';
    CREATE USER [{{IDENTITY_NAME}}] FROM EXTERNAL PROVIDER;
END
ELSE
BEGIN
    PRINT 'User [{{IDENTITY_NAME}}] already exists – skipping create.';
END

-- Grant roles only if not already a member
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
    WHERE r.name = 'db_datareader' AND u.name = '{{IDENTITY_NAME}}')
BEGIN
    PRINT 'Adding user [{{IDENTITY_NAME}}] to role db_datareader';
    ALTER ROLE [db_datareader] ADD MEMBER [{{IDENTITY_NAME}}];
END
ELSE PRINT 'User already in role db_datareader – skipping.';

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
    WHERE r.name = 'db_datawriter' AND u.name = '{{IDENTITY_NAME}}')
BEGIN
    PRINT 'Adding user [{{IDENTITY_NAME}}] to role db_datawriter';
    ALTER ROLE [db_datawriter] ADD MEMBER [{{IDENTITY_NAME}}];
END
ELSE PRINT 'User already in role db_datawriter – skipping.';

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
    WHERE r.name = 'db_ddladmin' AND u.name = '{{IDENTITY_NAME}}')
BEGIN
    PRINT 'Adding user [{{IDENTITY_NAME}}] to role db_ddladmin';
    ALTER ROLE [db_ddladmin] ADD MEMBER [{{IDENTITY_NAME}}];
END
ELSE PRINT 'User already in role db_ddladmin – skipping.';
