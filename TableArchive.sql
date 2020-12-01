-- setup
Declare @SourceTable varchar(99) = 'dbo.Person' 
       ,@NewOwner    varchar(99) = 'PersonArchive'
       ,@Criteria    varchar(99) = 'PersonID < 10';

drop table #tempDependency;

Create Table #TempDependency
(
    oType      int not null,  -- Not Used
    TableName  varchar(256) not null,
    TableOwner varchar(256) not null,
    TableLevel int not null
);

-- get all the dependencies
Insert into #tempDependency
Exec sp_MSdependencies @SourceTable, null, 0xC0008;

-- Working columns
Alter Table #tempDependency
Add SourceTable    Nvarchar(max) Null,
    NewTable       Nvarchar(max) Null,
    IdentityColumn Nvarchar(max) Null,
    IDDataType     Nvarchar(max) Null,
    FKParentTable  Nvarchar(max) Null,
    FKParentColumn Nvarchar(max) Null,
    FKChildColumn  Nvarchar(max) Null,
    ColumnList     Nvarchar(max) Null,
    Criteria       Nvarchar(max) Null;

-- result columns
Alter Table #tempDependency
Add CreateSQL      Nvarchar(max) Null,
    AlterSQL       Nvarchar(max) Null,
    IdentityFixSQL Nvarchar(max) Null,
    InsertSQL      Nvarchar(max) Null,
    DeleteSQL      Nvarchar(max) Null;

Update #tempDependency
Set SourceTable = TableOwner + '.' + TableName,
    NewTable    = @NewOwner  + '.' + TableName;

-- Fill the relationships
Update #TempDependency
Set FKParentTable    = pk.Table_Name
   ,FKParentColumn   = pt.Column_name 
   ,FKChildColumn    = cu.Column_name
From Information_Schema.Referential_Constraints c
    Inner Join Information_Schema.Table_Constraints fk On c.Constraint_Name = fk.Constraint_Name
    Inner Join Information_Schema.Table_Constraints pk On c.Unique_Constraint_Name = pk.Constraint_Name
    Inner Join Information_Schema.Key_Column_Usage  cu On c.Constraint_Name = cu.Constraint_Name
    Inner Join (    
            Select I1.Table_Name, I2.Column_name
            From Information_Schema.Table_Constraints I1
                Inner Join Information_Schema.Key_Column_Usage I2 On I1.Constraint_Name = I2.Constraint_Name
            Where I1.Constraint_type = 'Primary Key'
              ) pt On pt.Table_name = pk.Table_Name
Where #TempDependency.TableName = fk.Table_Name
  And pk.Table_Name in (Select TableName From #TempDependency)

-- is there an identity column?
Update #TempDependency
Set IdentityColumn = c.Column_Name
   ,IDDataType     = c.Data_Type
from Information_Schema.Columns c
Where ColumnProperty(object_id(c.Table_Schema + '.' + c.Table_Name), c.Column_Name, 'IsIdentity') = 1
  And #TempDependency.TableOwner = c.Table_Schema
  And #TempDependency.TableName = c.Table_Name;


-- gather the columns for each table
Update #TempDependency
Set ColumnList = Stuff ( (Select ', ' + Column_Name
                          From Information_Schema.Columns
                          Where Table_Name = #TempDependency.TableName
                            And Table_Schema = #TempDependency.TableOwner
                          Order By Ordinal_Position
                          For XML Path ('')
                         ), 1, 2, '')


-- generate the create SQLs
Update #TempDependency
Set CreateSQL      = 'Select * Into ' + NewTable + ' From ' + SourceTable + ' Where 1=2;'
   ,AlterSQL       = 'Alter Table '   + NewTable + ' Add ArchiveDate DateTime Null Default GetDate();'
   ,IdentityFixSQL = 'Alter Table '   + NewTable + ' Drop Column ' + IdentityColumn + '; '
                   + 'Alter Table '   + NewTable + ' Add ' + IdentityColumn + ' ' + IDDataType + ';' -- TODO: Support for character types

-- the move and clean up SQLs

-- first level
Update #TempDependency
Set DeleteSQL = 'Delete From ' + SourceTable + ' Where ' + @Criteria + ';'
   ,InsertSQL = 'Insert Into ' + NewTable + ' ( ' + ColumnList + ' ) ' 
              + 'Select ' + ColumnList + ' From ' + SourceTable + ' Where ' + @Criteria + ';'
Where TableLevel = 1

-- second level
Update #TempDependency
Set Criteria = ' Where ' + FKChildColumn + ' in ( Select ' + FKParentColumn + ' From ' + TableOwner + '.' + FKParentTable + ' Where ' + @Criteria + ' )'
Where FKParentTable = (Select t2.TableName From #TempDependency t2 Where t2.TableLevel = 1);

/*******************/
-- loop for level 3+
Declare @Name   varchar(256)
       ,@Owner  varchar(256)
       ,@Parent varchar(256);

Select Top 1 @Name   = TableName,
             @Owner  = TableOwner,
             @Parent = FKParentTable
From #TempDependency
Where Criteria is null
  And TableLevel > 1
Order by TableLevel;

-- start loop
While (@Name is not null)
Begin

    Declare @ParentCriteria varchar(256);

    Select @ParentCriteria = Criteria
    From #TempDependency
    Where TableName = @Parent; --owner?

    Update #TempDependency
    Set Criteria = ' Where ' + FKChildColumn + ' in ( Select ' + FKParentColumn + ' From ' + TableOwner + '.' + FKParentTable + @ParentCriteria + ' )'
    Where TableName  = @Name
      And TableOwner = @Owner;

    -- get ready to loop again
    Select @Name  = Null, 
           @Owner = Null,
           @Parent = Null;

    Select Top 1 @Name   = TableName,
                 @Owner  = TableOwner,
                 @Parent = FKParentTable
    From #TempDependency
    Where Criteria is null
    And TableLevel > 1
    Order by TableLevel;

End;


Update #TempDependency
Set DeleteSQL = 'Delete From ' + SourceTable + Criteria + ';'
   ,InsertSQL = 'Insert Into ' + NewTable + ' ( ' + ColumnList + ' ) ' 
              + 'Select ' + ColumnList + ' From ' + SourceTable + Criteria + ';'
Where TableLevel > 1;


-- fin

Select 'Create Schema ' + @NewOwner + ';'

Select *
from #TempDependency;

-- these are run in reverse order
Select deleteSQL
From #TempDependency
Order by TableLevel desc;



/*
Select *
from Information_Schema.Columns c
Inner Join #TempDependency t on t.TableName = c.Table_Name
Where ColumnProperty(object_id(c.Table_Schema + '.' + c.Table_Name), c.Column_Name, 'IsIdentity') = 1
  And t.TableOwner = c.Table_Schema
order by c.Table_Name
*/




/*
Select deleteSQL
From #TempDependency
Order by TableLevel desc;
*/

/*

*/


