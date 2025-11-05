-- Create 'todo' table if it does not exist (idempotent)
-- Note: Azure SQL does not yet have a native JSON column type; using NVARCHAR(MAX)
-- with an ISJSON() CHECK constraint to approximate JSON enforcement.
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name = 'todo' AND s.name = 'dbo')
BEGIN
    PRINT 'Creating table dbo.todo';
    CREATE TABLE dbo.todo (
        id INT IDENTITY(1,1) PRIMARY KEY,
        name NVARCHAR(100) NOT NULL,
        recommendations_json NVARCHAR(MAX) NULL,
        notes NVARCHAR(100) NULL,
        priority INT NOT NULL CONSTRAINT DF_todo_priority DEFAULT(0),
        completed BIT NOT NULL CONSTRAINT DF_todo_completed DEFAULT(0),
        due_date NVARCHAR(50) NULL,
        oid NVARCHAR(50) NULL,
        CONSTRAINT CK_todo_recommendations_json_isjson CHECK (recommendations_json IS NULL OR ISJSON(recommendations_json)=1)
    );
END
ELSE
BEGIN
    PRINT 'Table dbo.todo already exists – skipping create.';
END
