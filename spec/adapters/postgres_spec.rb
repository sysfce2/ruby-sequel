SEQUEL_ADAPTER_TEST = :postgres

require_relative 'spec_helper'

uses_pg = Sequel::Postgres::USES_PG if DB.adapter_scheme == :postgres
uses_pg_or_jdbc = uses_pg || DB.adapter_scheme == :jdbc

Sequel.extension :pg_extended_date_support
DB.extension :pg_array, :pg_range, :pg_row, :pg_inet, :pg_json, :pg_enum
begin
  DB.extension :pg_interval
rescue LoadError
end
DB.extension :pg_hstore if DB.type_supported?('hstore')
DB.extension :pg_multirange if DB.server_version >= 140000

if uses_pg && (auto_parameterize = ENV['SEQUEL_PG_AUTO_PARAMETERIZE'])
  case auto_parameterize
  when 'in_array_string'
    DB.opts[:treat_string_list_as_text_array] = 't'
    DB.extension :pg_auto_parameterize_in_array
  when 'in_array'
    DB.extension :pg_auto_parameterize_in_array
  when 'in_array_string_untyped'
    DB.opts[:treat_string_list_as_array] = 't'
    DB.extension :pg_auto_parameterize_in_array
  else
    DB.extension :pg_auto_parameterize
  end
end

describe 'PostgreSQL adapter' do
  before do
    @db = DB
    @db.disconnect
  end
  after do
    @db.disconnect
  end

  it "should handle case where status raises PGError" do
    proc do
      @db.synchronize do |c|
        def c.status; raise Sequel::Postgres::PGError end
        def c.execute_query(*); raise Sequel::Postgres::PGError end
        c.execute('SELECT 1')
      end
    end.must_raise Sequel::DatabaseDisconnectError
  end

  it "should handle case where execute_query returns nil" do
    @db.synchronize do |c|
      def c.execute_query(*); super; nil end
      c.execute('SELECT 1 AS v'){|v| v.must_be_nil}
    end
  end

  it "should handle prepared statement case where exec_prepared returns nil" do
    @db.synchronize do |c|
      def c.exec_prepared(*); super; nil end
      @db['SELECT 1 AS v'].prepare(:all, :test_prepared)
      @db.execute(:test_prepared){|v| v.must_be_nil}
    end
  end

  it "should handle prepared statement case where same variable is used more than once" do
    @db['SELECT (?::integer + ?::integer) AS v', :$v, :$v].prepare(:single_value, :test_prepared).call(:v=>2).must_equal 4
  end
end if uses_pg

describe 'A PostgreSQL database' do
  before do
    @db = DB
  end
  after do
    @db.drop_table?(:test)
    @db.timezone = nil
    Sequel.datetime_class = Time
  end

  it "should return true for table_exists? if table exists but is locked" do
    begin
      @db.create_table(:test){Integer :id}
      t = []
      @db[:test].lock('ACCESS EXCLUSIVE') do
        Thread.new do
          @db.synchronize do
            @db.run "SET lock_timeout = 1"
            t << @db.table_exists?(:test)
          end
         end.join
        Thread.new do
          @db.synchronize do
            @db.run "SET statement_timeout = 1"
            t << @db.table_exists?(:test)
          end
         end.join
      end
      t.must_equal [true, true]
    ensure
      # Must disconnect to ensure connections with lock/statement timeout are not left in the pool
      @db.disconnect
    end
  end if DB.server_version >= 90300

  it "should be able to handle various types of IN/NOT IN queries" do
    ds = @db.select(1)
    ds.where(2=>[2, 3]).wont_be_empty
    ds.where(4=>[2, 3]).must_be_empty
    ds.exclude(4=>[2, 3]).wont_be_empty
    ds.exclude(2=>[2, 4]).must_be_empty

    ds.where('2'=>%w[2 3]).wont_be_empty
    ds.where('4'=>%w[2 3]).must_be_empty
    ds.exclude('4'=>%w[2 3]).wont_be_empty
    ds.exclude('2'=>%w[2 3]).must_be_empty

    ds.where(2=>[2, 3].map{|i| BigDecimal(i)}).wont_be_empty
    ds.where(4=>[2, 3].map{|i| BigDecimal(i)}).must_be_empty
    ds.exclude(4=>[2, 3].map{|i| BigDecimal(i)}).wont_be_empty
    ds.exclude(2=>[2, 3].map{|i| BigDecimal(i)}).must_be_empty

    ds.where(Date.new(2021, 2)=>[2, 3].map{|i| Date.new(2021, i)}).wont_be_empty
    ds.where(Date.new(2021, 4)=>[2, 3].map{|i| Date.new(2021, i)}).must_be_empty
    ds.exclude(Date.new(2021, 4)=>[2, 3].map{|i| Date.new(2021, i)}).wont_be_empty
    ds.exclude(Date.new(2021, 2)=>[2, 3].map{|i| Date.new(2021, i)}).must_be_empty

    ds.where(DateTime.new(2021, 2)=>[2, 3].map{|i| DateTime.new(2021, i)}).wont_be_empty
    ds.where(DateTime.new(2021, 4)=>[2, 3].map{|i| DateTime.new(2021, i)}).must_be_empty
    ds.exclude(DateTime.new(2021, 4)=>[2, 3].map{|i| DateTime.new(2021, i)}).wont_be_empty
    ds.exclude(DateTime.new(2021, 2)=>[2, 3].map{|i| DateTime.new(2021, i)}).must_be_empty

    ds.where(Time.local(2021, 2)=>[2, 3].map{|i| Time.local(2021, i)}).wont_be_empty
    ds.where(Time.local(2021, 4)=>[2, 3].map{|i| Time.local(2021, i)}).must_be_empty
    ds.exclude(Time.local(2021, 4)=>[2, 3].map{|i| Time.local(2021, i)}).wont_be_empty
    ds.exclude(Time.local(2021, 2)=>[2, 3].map{|i| Time.local(2021, i)}).must_be_empty

    ds.where(Sequel::SQLTime.create(2, 0, 0)=>[2, 3].map{|i| Sequel::SQLTime.create(i, 0, 0)}).wont_be_empty
    ds.where(Sequel::SQLTime.create(4, 0, 0)=>[2, 3].map{|i| Sequel::SQLTime.create(i, 0, 0)}).must_be_empty
    ds.exclude(Sequel::SQLTime.create(4, 0, 0)=>[2, 3].map{|i| Sequel::SQLTime.create(i, 0, 0)}).wont_be_empty
    ds.exclude(Sequel::SQLTime.create(2, 0, 0)=>[2, 3].map{|i| Sequel::SQLTime.create(i, 0, 0)}).must_be_empty

    ds.where(2=>[2, 3].map{|i| Float(i)}).wont_be_empty
    ds.where(4=>[2, 3].map{|i| Float(i)}).must_be_empty
    ds.exclude(4=>[2, 3].map{|i| Float(i)}).wont_be_empty
    ds.exclude(2=>[2, 3].map{|i| Float(i)}).must_be_empty

    if @db.server_version >= 140000
      ds.where(2=>[2.0, 3.0, 1.0/0.0, -1.0/0.0, 0.0/0.0]).wont_be_empty
      ds.where(4=>[2.0, 3.0, 1.0/0.0, -1.0/0.0, 0.0/0.0]).must_be_empty
      ds.exclude(4=>[2.0, 3.0, 1.0/0.0, -1.0/0.0, 0.0/0.0]).wont_be_empty
      ds.exclude(2=>[2.0, 3.0, 1.0/0.0, -1.0/0.0, 0.0/0.0]).must_be_empty
    end

    ds.where(Sequel.blob('2')=>%w[2 3].map{|i| Sequel.blob(i)}).wont_be_empty
    ds.where(Sequel.blob('4')=>%w[2 3].map{|i| Sequel.blob(i)}).must_be_empty
    ds.exclude(Sequel.blob('4')=>%w[2 3].map{|i| Sequel.blob(i)}).wont_be_empty
    ds.exclude(Sequel.blob('2')=>%w[2 3].map{|i| Sequel.blob(i)}).must_be_empty

    ds.where(2=>[2, 3.0]).wont_be_empty
    ds.where(4=>[2, 3.0]).must_be_empty
    ds.exclude(4=>[2, 3.0]).wont_be_empty
    ds.exclude(2=>[2, 4.0]).must_be_empty

    ds.where(2=>[2]).wont_be_empty
    ds.where(4=>[2]).must_be_empty
    ds.exclude(4=>[2]).wont_be_empty
    ds.exclude(2=>[2]).must_be_empty

    ds.where(2=>[2, 3, nil]).wont_be_empty
    ds.where(4=>[2, 3, nil]).must_be_empty
    ds.exclude(4=>[2, 3, nil]).must_be_empty # NOT IN (..., NULL) predicate always false
    ds.exclude(2=>[2, 4, nil]).must_be_empty
  end

  it "should support UPDATE RETURNING with OLD/NEW" do
    @db.create_table(:test){Integer :id}
    @db[:test].insert(1)
    @db[:test].returning(Sequel::OLD[:id].as(:x), Sequel::NEW[:id].as(:y)).
      update(:id=>2).must_equal([{:x=>1, :y=>2}])
  end if DB.server_version >= 180000

  it "should provide a list of existing ordinary tables" do
    @db.create_table(:test){Integer :id}
    @db.tables.must_include :test
  end

  it "should handle providing a block to tables" do
    @db.create_table(:test){Integer :id}
    @db.tables{|ds| ds.where(:relkind=>'r').map{|r| r[:relname]}}.must_include 'test'
    @db.tables{|ds| ds.where(:relkind=>'p').map{|r| r[:relname]}}.wont_include 'test'
  end

  it "should handle blobs" do
    @db.create_table(:test){File :blob}
    blob = Sequel.blob("\0\1\254\255").force_encoding('BINARY')
    @db[:test].insert(blob)
    @db[:test].get(:blob).force_encoding('BINARY').must_equal blob
  end

  it "should not include :min_value or :max_value for enums" do
    begin
      @db.drop_enum(:intro_type) rescue nil
      @db.create_enum(:intro_type, %w(foo bar))
      @db.create_table(:test){intro_type :baz; column :bazs, 'intro_type[]'}
      sch = @db.schema(:test).first.last
      sch[:max_value].must_be_nil
      sch[:min_value].must_be_nil

      sch = @db.schema(:test).last.last
      sch[:max_value].must_be_nil
      sch[:min_value].must_be_nil
    ensure
      @db.drop_enum(:intro_type) rescue nil
    end
  end

  it "pg_auto_validate_enums plugin should validate enum values" do
    begin
      @db.drop_enum(:intro_type) rescue nil
      @db.create_enum(:intro_type, %w(foo bar))
      @db.create_table(:test){intro_type :baz}
      c = Sequel::Model(@db[:test])
      c.plugin :pg_auto_validate_enums
      o = c.new
      o.baz = "foo"
      o.valid?.must_equal true
      o.baz = "bar"
      o.valid?.must_equal true
      o.baz = "baz"
      o.valid?.must_equal false
      o.errors.must_equal(:baz => ['is not in range or set: ["foo", "bar"]'])
    ensure
      @db.drop_enum(:intro_type) rescue nil
    end
  end

  it "should not include :min_value or :max_value for arrays" do
    @db.create_table(:test){column :baz, 'integer[]'}
    sch = @db.schema(:test).first.last
    sch[:max_value].must_be_nil
    sch[:min_value].must_be_nil
  end

  {
    Date=>Date,
    'timestamp'=>Time,
    'timestamptz'=>Time,
  }.each do |type, klass|
    if DB.server_version >= 90600
      it "should correctly parse maximum and minimum values for #{type} columns" do
        @db.create_table!(:test){column :a, type}
        @db.timezone = :utc
        sch = @db.schema(:test).first.last
        max = sch[:max_value]
        min = sch[:min_value]
        max.must_be_kind_of klass
        min.must_be_kind_of klass
        insert_max = max
        insert_min = min
        if ENV['SEQUEL_PG_AUTO_PARAMETERIZE']
          @db.extension :pg_extended_date_support
          ds = @db[:test]
          if type == 'timestamptz'
            insert_max = Sequel.cast(max, 'timestamptz')
            insert_min = Sequel.cast(min, 'timestamptz')
          end
        else
          ds = @db[:test].with_extend(Sequel::Postgres::ExtendedDateSupport::DatasetMethods)
          if type == 'timestamptz'
            ds = ds.extension(:pg_timestamptz)
          end
        end
        proc{ds.insert(max+1)}.must_raise(Sequel::DatabaseError)
        proc{ds.insert(min-1)}.must_raise(Sequel::DatabaseError)
        ds.insert(insert_max)
        ds.insert(insert_min)
        min, max_value = ds.select_order_map(:a)
        min.must_be_kind_of klass
        max_value.must_equal max
      end
    else
      it "should not provide maximum and minimum values for #{type} columns" do
        @db.create_table!(:test){column :a, type}
        sch = @db.schema(:test).first.last
        sch[:max_value].must_be_nil
        sch[:min_value].must_be_nil
      end
    end

    if klass == Time
      it "should not provide maximum and minimum values for #{type} columns when Sequel.datetime_class is DateTime" do
        Sequel.datetime_class = DateTime
        @db.create_table!(:test){column :a, type}
        sch = @db.schema(:test).first.last
        sch[:max_value].must_be_nil
        sch[:min_value].must_be_nil
      end
    end
  end

  it "should provide a list of existing partitioned tables" do
    @db.create_table(:test, :partition_by => :id, :partition_type => :range){Integer :id}
    @db.tables.must_include :test
  end if DB.server_version >= 100000

  it "should provide a list of existing ordinary and partitioned tables" do
    @db.create_table(:test, :partition_by => :id, :partition_type => :range){Integer :id}
    @db.create_table(:test_1, :partition_of => :test){from 1; to 3}
    @db.create_table(:test_2, :partition_of => :test){from 3; to 4}
    @db.tables.must_include :test
    @db.tables.must_include :test_1
    @db.tables.must_include :test_2
  end if DB.server_version >= 100000

  it "should provide a list of indexes on partitioned tables" do
    @db.create_table(:test, :partition_by => :id, :partition_type => :range){Integer :id, :index=>true}
    @db.create_table(:test_1, :partition_of => :test){from 1; to 3}
    [:test, :test_1].each do  |t|
      h = @db.indexes(t)
      h.size.must_equal 1
      h.shift[1].must_equal(:columns=>[:id], :unique=>false, :deferrable=>nil)
    end
  end if DB.server_version >= 110000

  it "should provide a list of foreign keys on partitioned tables" do
    begin
      @db.create_table(:test){primary_key :i}
      @db.create_table(:test2, :partition_by => :id, :partition_type => :range){foreign_key :id, :test}
      fks = @db.foreign_key_list(:test2)
      fks.length.must_equal 1
      fks[0][:table].must_equal :test
      fks[0][:columns].must_equal [:id]
      fks[0][:key].must_equal [:i]
    ensure
      @db.drop_table?(:test2)
    end
  end if DB.server_version >= 110000
end

describe "PostgreSQL", '#create_table' do
  before do
    @db = DB
  end
  after do
    @db.drop_table?(:tmp_dolls, :unlogged_dolls)
    @db.default_string_column_size = nil
  end

  it "should support multiple types of string columns" do
    @db.default_string_column_size = 50
    @db.create_table(:tmp_dolls) do
      String :a1
      String :a2, :size=>10
      String :a3, :fixed=>true
      String :a4, :fixed=>true, :size=>10
      String :a5, :text=>false
      String :a6, :text=>false, :size=>10
      String :a7, :text=>true
    end
    @db.schema(:tmp_dolls).map{|k, v| v[:max_length]}.must_equal [nil, 10, 50, 10, 50, 10, nil]
  end

  it "should support range partitioned tables for single columns with :partition_* options" do
    @db.create_table(:tmp_dolls, :partition_by => :id, :partition_type=>:range){Integer :id}
    @db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){from 1; to 3}
    @db.create_table(:tmp_dolls_2, :partition_of => :tmp_dolls){from 3; to 4}
    @db[:tmp_dolls].insert(1)
    @db[:tmp_dolls].insert(2)
    @db[:tmp_dolls].insert(3)

    proc{@db[:tmp_dolls].insert(0)}.must_raise Sequel::DatabaseError
    proc{@db[:tmp_dolls].insert(5)}.must_raise Sequel::DatabaseError

    @db.create_table(:tmp_dolls_0, :partition_of => :tmp_dolls){from minvalue; to 1}
    @db.create_table(:tmp_dolls_3, :partition_of => :tmp_dolls){from 4; to maxvalue}

    @db[:tmp_dolls].insert(0)
    @db[:tmp_dolls].insert(5)

    @db[:tmp_dolls].order(:id).select_order_map(:id).must_equal [0,1,2,3,5]
    @db[:tmp_dolls_0].order(:id).select_order_map(:id).must_equal [0]
    @db[:tmp_dolls_1].order(:id).select_order_map(:id).must_equal [1,2]
    @db[:tmp_dolls_2].order(:id).select_order_map(:id).must_equal [3]
    @db[:tmp_dolls_3].order(:id).select_order_map(:id).must_equal [5]
  end if DB.server_version >= 100000 

  it "should support range partitioned tables for multiple columns with :partition_* options" do
    @db.create_table(:tmp_dolls, :partition_by => [:id, :id2], :partition_type=>:range){Integer :id; Integer :id2}
    @db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){from 1, 1; to 3, 3}
    @db.create_table(:tmp_dolls_2, :partition_of => :tmp_dolls){from 3, 3; to 4, 4}
    @db[:tmp_dolls].insert(1, 1)
    @db[:tmp_dolls].insert(2, 2)
    @db[:tmp_dolls].insert(3, 3)

    proc{@db[:tmp_dolls].insert(0, 0)}.must_raise Sequel::DatabaseError
    proc{@db[:tmp_dolls].insert(5, 5)}.must_raise Sequel::DatabaseError

    @db.create_table(:tmp_dolls_0, :partition_of => :tmp_dolls){from minvalue, minvalue; to 1, 1}
    @db.create_table(:tmp_dolls_3, :partition_of => :tmp_dolls){from 4, 4; to maxvalue, maxvalue}

    @db[:tmp_dolls].insert(0, 0)
    @db[:tmp_dolls].insert(5, 5)

    @db[:tmp_dolls].order(:id).select_order_map([:id, :id2]).must_equal [0,1,2,3,5].map{|x| [x,x]}
    @db[:tmp_dolls_0].order(:id).select_order_map([:id, :id2]).must_equal [0].map{|x| [x,x]}
    @db[:tmp_dolls_1].order(:id).select_order_map([:id, :id2]).must_equal [1,2].map{|x| [x,x]}
    @db[:tmp_dolls_2].order(:id).select_order_map([:id, :id2]).must_equal [3].map{|x| [x,x]}
    @db[:tmp_dolls_3].order(:id).select_order_map([:id, :id2]).must_equal [5].map{|x| [x,x]}
  end if DB.server_version >= 100000 

  it "should support list partitioned tables for single column with :partition_* options" do
    @db.create_table(:tmp_dolls, :partition_by => :id, :partition_type=>:list){Integer :id}
    @db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){values_in 1, 2}
    @db.create_table(:tmp_dolls_2, :partition_of => :tmp_dolls){values_in 3}
    @db[:tmp_dolls].insert(1)
    @db[:tmp_dolls].insert(2)
    @db[:tmp_dolls].insert(3)

    proc{@db[:tmp_dolls].insert(0)}.must_raise Sequel::DatabaseError
    proc{@db[:tmp_dolls].insert(5)}.must_raise Sequel::DatabaseError

    @db.create_table(:tmp_dolls_0, :partition_of => :tmp_dolls){values_in 0}
    @db.create_table(:tmp_dolls_3, :partition_of => :tmp_dolls){default}

    @db[:tmp_dolls].insert(0)
    @db[:tmp_dolls].insert(5)

    @db[:tmp_dolls].order(:id).select_order_map(:id).must_equal [0,1,2,3,5]
    @db[:tmp_dolls_0].order(:id).select_order_map(:id).must_equal [0]
    @db[:tmp_dolls_1].order(:id).select_order_map(:id).must_equal [1,2]
    @db[:tmp_dolls_2].order(:id).select_order_map(:id).must_equal [3]
    @db[:tmp_dolls_3].order(:id).select_order_map(:id).must_equal [5]
  end if DB.server_version >= 110000 

  it "should support hash partitioned tables for single column with :partition_* options" do
    @db.create_table(:tmp_dolls, :partition_by => :id, :partition_type=>:hash){Integer :id}
    @db.create_table(:tmp_dolls_0, :partition_of => :tmp_dolls){modulus 4; remainder 0}
    @db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){modulus 4; remainder 1}
    @db.create_table(:tmp_dolls_2, :partition_of => :tmp_dolls){modulus 4; remainder 2}
    @db.create_table(:tmp_dolls_3, :partition_of => :tmp_dolls){modulus 4; remainder 3}
    @db[:tmp_dolls].insert(1)
    @db[:tmp_dolls].insert(2)
    @db[:tmp_dolls].insert(3)
    @db[:tmp_dolls].insert(4)

    @db[:tmp_dolls].order(:id).select_order_map(:id).must_equal [1,2,3,4]
    [0,1,2,3].flat_map{|i| @db[:"tmp_dolls_#{i}"].select_order_map(:id)}.sort.must_equal [1,2,3,4]
  end if DB.server_version >= 110000 

  it "should support partitioned tables with create_table?" do
    @db.create_table(:tmp_dolls, :partition_by => :id, :partition_type=>:range){Integer :id}
    @db.create_table?(:tmp_dolls_1, :partition_of => :tmp_dolls){from 1; to 3}
    @db.create_table?(:tmp_dolls_2, :partition_of => :tmp_dolls){from 3; to 4}
    @db[:tmp_dolls].insert(1)
    @db[:tmp_dolls].insert(2)
    @db[:tmp_dolls].insert(3)

    proc{@db[:tmp_dolls].insert(0)}.must_raise Sequel::DatabaseError
    proc{@db[:tmp_dolls].insert(5)}.must_raise Sequel::DatabaseError

    @db.create_table?(:tmp_dolls_0, :partition_of => :tmp_dolls){from minvalue; to 1}
    @db.create_table?(:tmp_dolls_3, :partition_of => :tmp_dolls){from 4; to maxvalue}

    @db[:tmp_dolls].insert(0)
    @db[:tmp_dolls].insert(5)

    @db[:tmp_dolls].order(:id).select_order_map(:id).must_equal [0,1,2,3,5]
    @db[:tmp_dolls_0].order(:id).select_order_map(:id).must_equal [0]
    @db[:tmp_dolls_1].order(:id).select_order_map(:id).must_equal [1,2]
    @db[:tmp_dolls_2].order(:id).select_order_map(:id).must_equal [3]
    @db[:tmp_dolls_3].order(:id).select_order_map(:id).must_equal [5]
  end if DB.server_version >= 100000 

  it "should support partitioned tables with create_table!" do
    @db.create_table(:tmp_dolls, :partition_by => :id, :partition_type=>:range){Integer :id}
    @db.create_table!(:tmp_dolls_1, :partition_of => :tmp_dolls){from 1; to 3}
    @db.create_table!(:tmp_dolls_1, :partition_of => :tmp_dolls){from 1; to 3}
    @db.create_table!(:tmp_dolls_2, :partition_of => :tmp_dolls){from 3; to 4}
    @db.create_table!(:tmp_dolls_2, :partition_of => :tmp_dolls){from 3; to 4}
    @db[:tmp_dolls].insert(1)
    @db[:tmp_dolls].insert(2)
    @db[:tmp_dolls].insert(3)

    proc{@db[:tmp_dolls].insert(0)}.must_raise Sequel::DatabaseError
    proc{@db[:tmp_dolls].insert(5)}.must_raise Sequel::DatabaseError

    @db.create_table!(:tmp_dolls_0, :partition_of => :tmp_dolls){from minvalue; to 1}
    @db.create_table!(:tmp_dolls_0, :partition_of => :tmp_dolls){from minvalue; to 1}
    @db.create_table!(:tmp_dolls_3, :partition_of => :tmp_dolls){from 4; to maxvalue}
    @db.create_table!(:tmp_dolls_3, :partition_of => :tmp_dolls){from 4; to maxvalue}

    @db[:tmp_dolls].insert(0)
    @db[:tmp_dolls].insert(5)

    @db[:tmp_dolls].order(:id).select_order_map(:id).must_equal [0,1,2,3,5]
    @db[:tmp_dolls_0].order(:id).select_order_map(:id).must_equal [0]
    @db[:tmp_dolls_1].order(:id).select_order_map(:id).must_equal [1,2]
    @db[:tmp_dolls_2].order(:id).select_order_map(:id).must_equal [3]
    @db[:tmp_dolls_3].order(:id).select_order_map(:id).must_equal [5]
  end if DB.server_version >= 100000 

  it "should raise for unsupported partition types" do
    @db.create_table(:tmp_dolls, :partition_by => [:id, :id2], :partition_type=>:range){Integer :id; Integer :id2}
    proc{@db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){from 1, 1; to 3, 3; modulus 10}}.must_raise Sequel::Error
    proc{@db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){from 1, 1}}.must_raise Sequel::Error
    proc{@db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){modulus 10}}.must_raise Sequel::Error
    proc{@db.create_table(:tmp_dolls_1, :partition_of => :tmp_dolls){}}.must_raise Sequel::Error
  end if DB.server_version >= 100000 

  it "should not use a size for text columns" do
    @db.create_table(:tmp_dolls){String :description, text: true, size: :long}
    @db.tables.must_include :tmp_dolls
  end

  it "should create an unlogged table" do
    @db.create_table(:unlogged_dolls, :unlogged => true){text :name}
  end if DB.server_version >= 90100

  it "should create a table inheriting from another table" do
    @db.create_table(:unlogged_dolls){text :name}
    @db.create_table(:tmp_dolls, :inherits=>:unlogged_dolls){}
    @db[:tmp_dolls].insert('a')
    @db[:unlogged_dolls].all.must_equal [{:name=>'a'}]
  end

  it "should create a table inheriting from multiple tables" do
    begin
      @db.create_table(:unlogged_dolls){text :name}
      @db.create_table(:tmp_dolls){text :bar}
      @db.create_table!(:items, :inherits=>[:unlogged_dolls, :tmp_dolls]){text :foo}
      @db[:items].insert(:name=>'a', :bar=>'b', :foo=>'c')
      @db[:unlogged_dolls].all.must_equal [{:name=>'a'}]
      @db[:tmp_dolls].all.must_equal [{:bar=>'b'}]
      @db[:items].all.must_equal [{:name=>'a', :bar=>'b', :foo=>'c'}]
    ensure
      @db.drop_table?(:items)
    end
  end

  it "should have #immediate_constraints and #defer_constraints for deferring/checking deferrable constraints" do
    @db.create_table(:tmp_dolls) do
      primary_key :id
      foreign_key(:x, :tmp_dolls, :foreign_key_constraint_name=>:x_fk, :deferrable=>true)
      foreign_key(:y, :tmp_dolls, :foreign_key_constraint_name=>:y_fk, :deferrable=>true)
    end

    ds = @db[:tmp_dolls]
    @db.transaction do
      @db.immediate_constraints
      ds.insert(:id=>1)
      @db.defer_constraints
      ds.insert(:id=>2, :x=>1, :y=>3)
      proc{@db.immediate_constraints}.must_raise Sequel::ForeignKeyConstraintViolation
    end
    @db[:tmp_dolls].must_be_empty
    
    @db.transaction do
      @db.immediate_constraints
      @db.defer_constraints(:constraints=>:y_fk)
      ds.insert(:id=>1, :x=>1, :y=>2)
      proc{@db.immediate_constraints}.must_raise Sequel::ForeignKeyConstraintViolation
    end
    @db[:tmp_dolls].must_be_empty

    @db.transaction do
      @db.defer_constraints
      ds.insert(:id=>1, :x=>1, :y=>2)
      proc{@db.immediate_constraints(:constraints=>:y_fk)}.must_raise Sequel::ForeignKeyConstraintViolation
    end
    @db[:tmp_dolls].must_be_empty

    @db.transaction do
      @db.immediate_constraints
      @db.defer_constraints(:constraints=>[:x_fk, :y_fk])
      ds.insert(:id=>1, :x=>3, :y=>2)
      ds.update(:id=>1, :x=>1, :y=>1)
    end
    @db[:tmp_dolls].count.must_equal 1
  end

  it "should have #check_constraints method for getting check constraints" do
    @db.create_table(:tmp_dolls) do
      Integer :i
      Integer :j
      constraint(:ic, Sequel[:i] > 2)
      constraint(:jc, Sequel[:j] > 2)
      constraint(:ijc, Sequel[:i] - Sequel[:j] > 2)
    end
    @db.check_constraints(:tmp_dolls).must_equal(:ic=>{:definition=>"CHECK ((i > 2))", :columns=>[:i], validated: true, enforced: true}, :jc=>{:definition=>"CHECK ((j > 2))", :columns=>[:j], validated: true, enforced: true}, :ijc=>{:definition=>"CHECK (((i - j) > 2))", :columns=>[:i, :j], validated: true, enforced: true})
  end

  it "should have #check_constraints return check constraints where columns are unknown" do
    begin
      @db.create_table(:tmp_dolls) do
        Integer :i
        Integer :j
      end
      @db.run "CREATE OR REPLACE FUNCTION valid_tmp_dolls(t1 tmp_dolls) RETURNS boolean AS 'SELECT false' LANGUAGE SQL;"
      @db.alter_table(:tmp_dolls) do
        add_constraint(:valid_tmp_dolls, Sequel.function(:valid_tmp_dolls, :tmp_dolls))
      end

      @db.check_constraints(:tmp_dolls).must_equal(:valid_tmp_dolls=>{:definition=>"CHECK (valid_tmp_dolls(tmp_dolls.*))", :columns=>[], validated: true, enforced: true})
    ensure
      @db.run "ALTER TABLE tmp_dolls DROP CONSTRAINT IF EXISTS valid_tmp_dolls"
      @db.run "DROP FUNCTION IF EXISTS valid_tmp_dolls(tmp_dolls)"
    end
  end if DB.server_version >= 90000

  it "should support :if_exists option to drop_column" do
    @db.create_table(:tmp_dolls){Integer :a; Integer :b}
    2.times do
      @db.drop_column :tmp_dolls, :b, :if_exists=>true
      @db[:tmp_dolls].columns.must_equal [:a]
    end
  end if DB.server_version >= 90000

  it "should support primary_key with :type=>:smallserial, :type=>:serial or :type=>:bigserial" do
    [:smallserial, :serial, :bigserial, 'smallserial', 'serial', 'bigserial'].each do |type|
      @db.create_table!(:tmp_dolls){primary_key :id, :type=>type}
      @db[:tmp_dolls].insert
      @db[:tmp_dolls].get(:id).must_equal 1
    end
  end if DB.server_version >= 100002

  it "should support primary_key with :serial=>true" do
    @db.create_table!(:tmp_dolls){primary_key :id, :serial=>true}
    @db[:tmp_dolls].insert
    @db[:tmp_dolls].get(:id).must_equal 1
  end if DB.server_version >= 100002

  it "should support primary_key with :Bignum type and serial=>true" do
    @db.create_table!(:tmp_dolls){primary_key :id, :type=>:Bignum, :serial=>true}
    @db[:tmp_dolls].insert(2**48)
    @db[:tmp_dolls].get(:id).must_equal(2**48)
  end

  it "should support Bignum column with serial=>true" do
    @db.create_table!(:tmp_dolls){Bignum :id, :serial=>true, :primary_key=>true}
    @db[:tmp_dolls].insert(2**48)
    @db[:tmp_dolls].get(:id).must_equal(2**48)
  end

  it "should support creating identity columns on non-primary key tables" do
    @db.create_table(:tmp_dolls){Integer :a, :identity=>true}
    2.times do
      @db[:tmp_dolls].insert
    end
    @db[:tmp_dolls].select_order_map(:a).must_equal [1, 2]
    @db[:tmp_dolls].insert(:a=>2)
    @db[:tmp_dolls].select_order_map(:a).must_equal [1, 2, 2]
    @db[:tmp_dolls].insert(:a=>4)
    @db[:tmp_dolls].select_order_map(:a).must_equal [1, 2, 2, 4]
    @db[:tmp_dolls].overriding_user_value.insert(:a=>5)
    @db[:tmp_dolls].select_order_map(:a).must_equal [1, 2, 2, 3, 4]
  end if DB.server_version >= 100002

  it "should support creating identity columns generated always" do
    @db.create_table(:tmp_dolls){primary_key :id, :identity=>:always}
    2.times do
      @db[:tmp_dolls].insert
    end
    @db[:tmp_dolls].select_order_map(:id).must_equal [1, 2]
    proc{@db[:tmp_dolls].insert(:id=>2)}.must_raise Sequel::DatabaseError
    @db[:tmp_dolls].overriding_system_value.insert(:id=>4)
    @db[:tmp_dolls].select_order_map(:id).must_equal [1, 2, 4]
    @db[:tmp_dolls].insert
    @db[:tmp_dolls].select_order_map(:id).must_equal [1, 2, 3, 4]
  end if DB.server_version >= 100002

  it "should handle generated column overrides using override value at time of merge_insert call" do
    @db.create_table(:tmp_dolls){primary_key :id, :identity=>:always}
    @db.create_table(:unlogged_dolls){Integer :i}
    @db[:unlogged_dolls].insert(10)
    @db[:unlogged_dolls].insert(20)
    @db[:tmp_dolls].
      merge_using(:unlogged_dolls, :id=>:i).
      overriding_system_value.
      merge_insert(:i){i > 15}.
      overriding_user_value.
      merge_insert(:i).
      merge
    @db[:tmp_dolls].select_order_map(:id).must_equal [1, 20]
  end if DB.server_version >= 150000

  it "should support converting serial columns to identity columns" do
    @db.create_table(:tmp_dolls){primary_key :id, :identity=>false, :serial=>true}
    sch = @db.schema(:tmp_dolls)[0][1]
    sch[:default].must_match(/nextval/)
    sch[:auto_increment].must_equal true

    2.times do
      @db[:tmp_dolls].insert
    end

    @db.convert_serial_to_identity(:tmp_dolls)
    sch = @db.schema(:tmp_dolls)[0][1]
    sch[:default].must_be_nil
    sch[:auto_increment].must_equal true

    @db[:tmp_dolls].insert
    @db[:tmp_dolls].insert(5)
    @db[:tmp_dolls].select_order_map(:id).must_equal [1, 2, 3, 5]

    # Make sure it doesn't break if already converted
    @db.convert_serial_to_identity(:tmp_dolls)
  end if DB.server_version >= 100002 && DB.get{current_setting('is_superuser')} == 'on'

  it "should support converting serial columns to identity columns when using the :column option" do
    @db.create_table(:tmp_dolls){Integer :i, :primary_key=>true; serial :id}
    sch = @db.schema(:tmp_dolls)[1][1]
    sch[:default].must_match(/nextval/)

    2.times do |i|
      @db[:tmp_dolls].insert(:i=>-i)
    end

    # Automatic conversion should not work
    proc{@db.convert_serial_to_identity(:tmp_dolls)}.must_raise Sequel::Error

    # Conversion of type without related sequence should not work
    proc{@db.convert_serial_to_identity(:tmp_dolls, :column=>:i)}.must_raise Sequel::Error

    @db.convert_serial_to_identity(:tmp_dolls, :column=>:id)
    sch = @db.schema(:tmp_dolls)[1][1]
    sch[:default].must_be_nil

    @db[:tmp_dolls].insert(:i=>200)
    @db[:tmp_dolls].insert(:i=>300, :id=>5)
    @db[:tmp_dolls].select_order_map(:id).must_equal [1, 2, 3, 5]

    # Make sure it doesn't break if already converted
    @db.convert_serial_to_identity(:tmp_dolls, :column=>:id)
  end if DB.server_version >= 100002 && DB.get{current_setting('is_superuser')} == 'on'

  it "should support creating generated columns" do
    @db.create_table(:tmp_dolls){Integer :a; Integer :b; Integer :c, :generated_always_as=>Sequel[:a] * 2 + :b + 1}
    @db[:tmp_dolls].insert(:a=>100, :b=>10)
    @db[:tmp_dolls].select_order_map([:a, :b, :c]).must_equal [[100, 10, 211]]
  end if DB.server_version >= 120000

  it "should include :generated entry in schema for whether the column is generated" do
    @db.create_table(:tmp_dolls){Integer :a; Integer :b; Integer :c, :generated_always_as=>Sequel[:a] * 2 + :b + 1}
    @db.schema(:tmp_dolls).map{|_,v| v[:generated]}.must_equal [false, false, true]
  end if DB.server_version >= 120000

  it "should include :comment entry in schema for whether the column is commented" do
    @db.create_table(:tmp_dolls){Integer :a; Integer :b}
    @db.run("COMMENT ON COLUMN tmp_dolls.b IS 'blah'")
    @db.schema(:tmp_dolls).map{|_,v| v[:comment]}.must_equal [nil, 'blah']
  end

  it "should support deferred primary key and unique constraints on columns" do
    @db.create_table(:tmp_dolls){primary_key :id, :primary_key_deferrable=>true; Integer :i, :unique=>true, :unique_deferrable=>true}
    @db[:tmp_dolls].insert(:i=>10)
    DB.transaction do
      @db[:tmp_dolls].insert(:id=>1, :i=>1)
      @db[:tmp_dolls].insert(:id=>10, :i=>10)
      @db[:tmp_dolls].where(:i=>1).update(:id=>2)
      @db[:tmp_dolls].where(:id=>10).update(:i=>2)
    end
    @db[:tmp_dolls].select_order_map([:id, :i]).must_equal [[1, 10], [2, 1], [10, 2]]
  end if DB.server_version >= 90000

  it "should support pg_loose_count extension" do
    @db.extension :pg_loose_count
    @db.create_table(:tmp_dolls){text :name}
    @db.loose_count(:tmp_dolls).must_be_kind_of(Integer)
    [0, -1].must_include @db.loose_count(:tmp_dolls)
    [0, -1].must_include @db.loose_count(Sequel[:public][:tmp_dolls])
    @db[:tmp_dolls].insert('a')
    @db << 'VACUUM ANALYZE tmp_dolls'
    @db.loose_count(:tmp_dolls).must_equal 1
    @db.loose_count(Sequel[:public][:tmp_dolls]).must_equal 1
  end
end

describe "PostgreSQL temporary table/view support" do
  before(:all) do
    @db = DB
    @db.disconnect
  end
  after do
    @db.drop_view(:tmp_dolls_view, :if_exists=>true, :cascade=>true) rescue nil
    @db.drop_table?(:tmp_dolls)
  end

  it "should create a temporary table" do
    @db.create_table(:tmp_dolls, :temp => true){text :name}
    @db.table_exists?(:tmp_dolls).must_equal true
    @db.disconnect
    @db.table_exists?(:tmp_dolls).must_equal false
  end

  it "temporary table should support :on_commit option" do
    @db.drop_table?(:some_table)
    @db.transaction do
      @db.create_table(:some_table, :temp => true, :on_commit => :drop){text :name}
    end
    @db.table_exists?(:some_table).must_equal false

    @db.transaction do
      @db.create_table(:some_table, :temp => true, :on_commit => :delete_rows){text :name}
      @db[:some_table].insert('a')
    end
    @db.table_exists?(:some_table).must_equal true
    @db[:some_table].empty?.must_equal true

    @db.drop_table(:some_table)
    @db.transaction do
      @db.create_table(:some_table, :temp => true, :on_commit => :preserve_rows){text :name}
      @db[:some_table].insert('a')
    end
    @db.table_exists?(:some_table).must_equal true
    @db[:some_table].count.must_equal 1
    @db.drop_table(:some_table)
  end

  it "temporary table should accept :on_commit with :as option" do
    @db.drop_table?(:some_table)
    @db.transaction do
      @db.create_table(:some_table, :temp => true, :on_commit => :drop, :as => 'select 1')
    end
    @db.table_exists?(:some_table).must_equal false
  end

  it ":on_commit should raise error if not used on a temporary table" do
    proc{@db.create_table(:some_table, :on_commit => :drop)}.must_raise(Sequel::Error)
  end

  it ":on_commit should raise error if given unsupported value" do
    proc{@db.create_table(:some_table, :temp => true, :on_commit => :unsupported){text :name}}.must_raise(Sequel::Error)
  end

  it "should not allow to pass both :temp and :unlogged" do
    proc do
      @db.create_table(:temp_unlogged_dolls, :temp => true, :unlogged => true){text :name}
    end.must_raise(Sequel::Error, "can't provide both :temp and :unlogged to create_table")
  end

  it "should support temporary views" do
    @db.create_table(:tmp_dolls, :temp => true){Integer :number}
    @db[:tmp_dolls].insert(10)
    @db[:tmp_dolls].insert(20)
    @db.create_view(:tmp_dolls_view, @db[:tmp_dolls].where(:number=>10), :temp=>true)
    @db[:tmp_dolls_view].map(:number).must_equal [10]
    @db.create_or_replace_view(:tmp_dolls_view, @db[:tmp_dolls].where(:number=>20),  :temp=>true)
    @db[:tmp_dolls_view].map(:number).must_equal [20]
  end

  it "should support security_invoker view option" do
    @db.create_table(:tmp_dolls, :temp => true){Integer :number}
    @db[:tmp_dolls].insert(10)
    @db.create_view(:tmp_dolls_view, @db[:tmp_dolls].where(:number=>10), :temp=>true, :security_invoker=>true)
    @db[:tmp_dolls_view].count.must_equal 1
  end if DB.server_version >= 150000
end

describe "PostgreSQL views" do
  before do
    @db = DB
    @db.drop_table?(:items, :cascade=>true)
    @db.create_table(:items){Integer :number}
    @db[:items].insert(10)
    @db[:items].insert(20)
  end
  after do
    @opts ||={}
    @db.drop_view(:items_view, @opts.merge(:if_exists=>true, :cascade=>true)) rescue nil
    @db.drop_table?(:items)
  end

  it "should support recursive views" do
    @db.create_view(:items_view, @db[:items].where(:number=>10).union(@db[:items, :items_view].where(Sequel.-(:number, 5)=>:n).select(:number), :all=>true, :from_self=>false), :recursive=>[:n])
    @db[:items_view].select_order_map(:n).must_equal [10]
    @db[:items].insert(15)
    @db[:items_view].select_order_map(:n).must_equal [10, 15, 20]
  end if DB.server_version >= 90300

  it "should support materialized views" do
    @opts = {:materialized=>true}
    @db.create_view(:items_view, @db[:items].where{number >= 10}, @opts)
    @db[:items_view].select_order_map(:number).must_equal [10, 20]
    @db[:items].insert(15)
    @db[:items_view].select_order_map(:number).must_equal [10, 20]
    @db.refresh_view(:items_view)
    @db[:items_view].select_order_map(:number).must_equal [10, 15, 20]
    @db.views.wont_include :items_view
    @db.views(@opts).must_include :items_view
  end if DB.server_version >= 90300

  it "should support replacing materialized views" do
    @opts = {:materialized=>true}
    @db[:items].insert(15)
    @db.create_or_replace_view(:items_view, @db[:items].where{number > 10}, @opts)
    @db[:items_view].select_order_map(:number).must_equal [15, 20]
    @db.create_or_replace_view(:items_view, @db[:items].where{number > 15}, @opts)
    @db[:items_view].select_order_map(:number).must_equal [20]
  end if DB.server_version >= 90300

  it "should support refreshing materialized views concurrently" do
    @opts = {:materialized=>true}
    @db.create_view(:items_view, @db[:items].where{number >= 10}, @opts)
    @db.refresh_view(:items_view)
    proc{@db.refresh_view(:items_view, :concurrently=>true)}.must_raise(Sequel::DatabaseError)
    @db.add_index :items_view, :number, :unique=>true
    @db.refresh_view(:items_view, :concurrently=>true)
  end if DB.server_version >= 90400

  it "should support specifying tablespaces for materialized views" do
    @opts = {:materialized=>true}
    @db.create_view(:items_view, @db[:items].where{number >= 10}, :materialized=>true, :tablespace=>:pg_default)
  end if DB.server_version >= 90300

  it "should support :if_exists=>true for not raising an error if the view does not exist" do
    @db.drop_view(:items_view, :if_exists=>true)
  end
end 
    
describe "PostgreSQL", 'INSERT ON CONFLICT' do
  before(:all) do
    @db = DB
    @db.create_table!(:ic_test){Integer :a; Integer :b; Integer :c; TrueClass :c_is_unique, :default=>false; unique :a, :name=>:ic_test_a_uidx; unique [:b, :c], :name=>:ic_test_b_c_uidx; index [:c], :where=>:c_is_unique, :unique=>true}
    @ds = @db[:ic_test]
  end
  before do
    @ds.delete
  end
  after(:all) do
    @db.drop_table?(:ic_test)
  end

  it "Dataset#supports_insert_conflict? should be true" do
    @ds.supports_insert_conflict?.must_equal true
  end

  it "Dataset#insert_ignore and insert_conflict should ignore uniqueness violations" do
    @ds.insert(1, 2, 3)
    @ds.insert(10, 11, 3, true)
    proc{@ds.insert(1, 3, 4)}.must_raise Sequel::UniqueConstraintViolation
    proc{@ds.insert(11, 12, 3, true)}.must_raise Sequel::UniqueConstraintViolation
    @ds.insert_ignore.insert(1, 3, 4).must_be_nil
    @ds.insert_conflict.insert(1, 3, 4).must_be_nil
    @ds.insert_conflict.insert(11, 12, 3, true).must_be_nil
    @ds.insert_conflict(:target=>:a).insert(1, 3, 4).must_be_nil
    @ds.insert_conflict(:target=>:c, :conflict_where=>:c_is_unique).insert(11, 12, 3, true).must_be_nil
    @ds.insert_conflict(:constraint=>:ic_test_a_uidx).insert(1, 3, 4).must_be_nil
    @ds.all.must_equal [{:a=>1, :b=>2, :c=>3, :c_is_unique=>false}, {:a=>10, :b=>11, :c=>3, :c_is_unique=>true}]
  end

  it "Dataset#insert_ignore and insert_conflict should work with multi_insert/import" do
    @ds.insert(1, 2, 3)
    @ds.insert_ignore.multi_insert([{:a=>1, :b=>3, :c=>4}])
    @ds.insert_ignore.import([:a, :b, :c], [[1, 3, 4]])
    @ds.all.must_equal [{:a=>1, :b=>2, :c=>3, :c_is_unique=>false}]
    @ds.insert_conflict(:target=>:a, :update=>{:b=>3}).import([:a, :b, :c], [[1, 3, 4]])
    @ds.all.must_equal [{:a=>1, :b=>3, :c=>3, :c_is_unique=>false}]
    @ds.insert_conflict(:target=>:a, :update=>{:b=>4}).multi_insert([{:a=>1, :b=>5, :c=>6}])
    @ds.all.must_equal [{:a=>1, :b=>4, :c=>3, :c_is_unique=>false}]
    end

  it "Dataset#insert_conflict should handle upserts" do
    @ds.insert(1, 2, 3)
    @ds.insert_conflict(:target=>:a, :update=>{:b=>3}).insert(1, 3, 4).must_be_nil
    @ds.all.must_equal [{:a=>1, :b=>3, :c=>3, :c_is_unique=>false}]
    @ds.insert_conflict(:target=>[:b, :c], :update=>{:c=>5}).insert(5, 3, 3).must_be_nil
    @ds.all.must_equal [{:a=>1, :b=>3, :c=>5, :c_is_unique=>false}]
    @ds.insert_conflict(:constraint=>:ic_test_a_uidx, :update=>{:b=>4}).insert(1, 3).must_be_nil
    @ds.all.must_equal [{:a=>1, :b=>4, :c=>5, :c_is_unique=>false}]
    @ds.insert_conflict(:constraint=>:ic_test_a_uidx, :update=>{:b=>5}, :update_where=>{Sequel[:ic_test][:b]=>4}).insert(1, 3, 4).must_be_nil
    @ds.all.must_equal [{:a=>1, :b=>5, :c=>5, :c_is_unique=>false}]
    @ds.insert_conflict(:constraint=>:ic_test_a_uidx, :update=>{:b=>6}, :update_where=>{Sequel[:ic_test][:b]=>4}).insert(1, 3, 4).must_be_nil
    @ds.all.must_equal [{:a=>1, :b=>5, :c=>5, :c_is_unique=>false}]
  end

  it "Dataset#insert_conflict should support table aliases" do
    @ds = @db[Sequel[:ic_test].as(:foo)]
    @ds.insert(1, 2, 5)
    proc{@ds.insert(1, 3, 4)}.must_raise Sequel::UniqueConstraintViolation
    @ds.insert_conflict(:target=>:a, :update=>{:b=>Sequel[:foo][:c] + Sequel[:excluded][:c]}).insert(1, 7, 10)
    @ds.all.must_equal [{:a=>1, :b=>15, :c=>5, :c_is_unique=>false}]
  end
end if DB.server_version >= 90500

describe "A PostgreSQL database" do
  before(:all) do
    @db = DB
    @db.create_table!(Sequel[:public][:testfk]){primary_key :id; foreign_key :i, Sequel[:public][:testfk]}
  end
  after(:all) do
    @db.drop_table?(Sequel[:public][:testfk])
  end

  it "should provide the server version" do
    @db.server_version.must_be :>,  70000
  end

  it "should create a dataset using the VALUES clause via #values" do
    @db.values([[1, 2], [3, 4]]).map([:column1, :column2]).must_equal [[1, 2], [3, 4]]
  end

  it "should support compounds with VALUES" do
    @db.values([[1, 2]]).union(@db.values([[3, 4]])).map([:column1, :column2]).must_equal [[1, 2], [3, 4]]
  end

  it "#values should error if given an empty array" do
    proc{@db.values([])}.must_raise(Sequel::Error)
  end

  it "#empty? should return false for datasets using VALUES" do
    @db.values([[nil]]).empty?.must_equal false
  end

  it "#count should return correct number of rows for datasets using VALUES when called without arguments" do
    @db.values([[100]]).count.must_equal 1
    @db.values([[100, 1]]).count.must_equal 1
    @db.values([[100], [200]]).count.must_equal 2
    @db.values([[100, 10], [200, 10]]).count.must_equal 2
  end

  it "#count should return correct number of rows for datasets using VALUES when called with arguments" do
    @db.values([[100]]).count(:column1).must_equal 1
    @db.values([[nil]]).count{:column1}.must_equal 0
  end

  it "should correctly handle various numbers of columns" do
    [1, 2, 15, 16, 17, 63, 64, 65, 255, 256, 257, 1663, 1664].each do |i|
      DB.get((1..i).map{|j| Sequel.as(j, "c#{j}")}).must_equal((1..i).to_a)
    end
    proc{DB.get((1..1665).map{|j| Sequel.as(j, "c#{j}")})}.must_raise Sequel::DatabaseError
  end

  it "should support ordering in aggregate functions" do
    @db.from(@db.values([['1'], ['2']]).as(:t, [:a])).get{string_agg(:a, '-').order(Sequel.desc(:a)).as(:c)}.must_equal '2-1'
  end if DB.server_version >= 90000

  it "should support ordering and limiting with #values" do
    @db.values([[1, 2], [3, 4]]).reverse(:column2, :column1).limit(1).map([:column1, :column2]).must_equal [[3, 4]]
    @db.values([[1, 2], [3, 4]]).reverse(:column2, :column1).offset(1).map([:column1, :column2]).must_equal [[1, 2]]
  end

  it "should support subqueries with #values" do
    @db.values([[1, 2]]).from_self.cross_join(@db.values([[3, 4]]).as(:x, [:c1, :c2])).map([:column1, :column2, :c1, :c2]).must_equal [[1, 2, 3, 4]]
  end

  it "should support JOIN USING" do
    @db.from(@db.values([[1, 2]]).as(:x, [:c1, :c2])).join(@db.values([[1, 2]]).as(:y, [:c1, :c2]), [:c1, :c2]).all.must_equal [{:c1=>1, :c2=>2}]
  end

  it "should support column aliases for JOIN USING" do
    @db.from(@db.values([[1, 2]]).as(:x, [:c1, :c2])).join(@db.values([[1, 2]]).as(:y, [:c1, :c2]), Sequel.as([:c1, :c2], :foo)).select_all(:foo).all.must_equal [{:c1=>1, :c2=>2}]
  end if DB.server_version >= 140000

  it "should respect the :read_only option per-savepoint" do
    proc{@db.transaction{@db.transaction(:savepoint=>true, :read_only=>true){@db[Sequel[:public][:testfk]].insert}}}.must_raise(Sequel::DatabaseError)
    proc{@db.transaction(:auto_savepoint=>true, :read_only=>true){@db.transaction(:read_only=>false){@db[Sequel[:public][:testfk]].insert}}}.must_raise(Sequel::DatabaseError)
    @db[Sequel[:public][:testfk]].delete
    @db.transaction{@db[Sequel[:public][:testfk]].insert; @db.transaction(:savepoint=>true, :read_only=>true){@db[Sequel[:public][:testfk]].all;}}
    @db.transaction{@db.transaction(:savepoint=>true, :read_only=>true){}; @db[Sequel[:public][:testfk]].insert}
    @db.transaction{@db[Sequel[:public][:testfk]].all; @db.transaction(:savepoint=>true, :read_only=>true){@db[Sequel[:public][:testfk]].all;}}
  end

  it "should support disable_insert_returning" do
    ds = @db[Sequel[:public][:testfk]].disable_insert_returning
    ds.delete
    ds.insert.must_be_nil
    id = ds.max(:id)
    ds.select_order_map([:id, :i]).must_equal [[id, nil]]
    ds.insert(:i=>id).must_be_nil
    ds.select_order_map([:id, :i]).must_equal [[id, nil], [id+1, id]]
    ds.insert_select(:i=>ds.max(:id)).must_be_nil
    ds.select_order_map([:id, :i]).must_equal [[id, nil], [id+1, id]]
    c = Class.new(Sequel::Model(ds))
    c.class_eval do
      def before_create
        self.id = model.max(:id)+1
        super
      end
    end
    c.create(:i=>id+1).must_equal c.load(:id=>id+2, :i=>id+1)
    ds.select_order_map([:id, :i]).must_equal [[id, nil], [id+1, id], [id+2, id+1]]
    ds.delete
  end

  it "should support functions with and without quoting" do
    ds = @db[Sequel[:public][:testfk]]
    ds.delete
    ds.insert
    ds.get{sum(1)}.must_equal 1
    ds.get{Sequel.function('pg_catalog.sum', 1)}.must_equal 1
    ds.get{sum.function(1)}.must_equal 1
    ds.get{pg_catalog[:sum].function(1)}.must_equal 1
    ds.delete
  end

  it "should support a :qualify option to tables and views" do
    @db.tables(:qualify=>true).must_include(Sequel.qualify('public', 'testfk'))
    begin
      @db.create_view(:testfkv, @db[:testfk])
      @db.views(:qualify=>true).must_include(Sequel.qualify('public', 'testfkv'))
    ensure
      @db.drop_view(:testfkv)
    end
  end

  it "should handle double underscores in tables when using the qualify option" do
    @db.create_table!(Sequel.qualify(:public, 'test__fk')){Integer :a}
    @db.tables(:qualify=>true).must_include(Sequel.qualify('public', 'test__fk'))
    @db.drop_table(Sequel.qualify(:public, 'test__fk'))
  end

  it "should not typecast the int2vector type incorrectly" do
    @db.get(Sequel.cast('10 20', :int2vector)).wont_equal 10
  end

  it "should not typecast the money type incorrectly" do
    @db.get(Sequel.cast('10.01', :money)).wont_equal 0
  end

  it "should correctly parse the schema" do
    [[[:id, 23], [:i, 23]], [[:id, 20], [:i, 20]]].must_include @db.schema(Sequel[:public][:testfk], :reload=>true).map{|c,s| [c, s[:oid]]}
  end

  it "should parse foreign keys for tables in a schema" do
    @db.foreign_key_list(Sequel[:public][:testfk]).must_equal [{:on_delete=>:no_action, :on_update=>:no_action, :columns=>[:i], :key=>[:id], :deferrable=>false, :table=>Sequel.qualify(:public, :testfk), :name=>:testfk_i_fkey, validated: true, enforced: true}]
    @db.foreign_key_list(Sequel[:public][:testfk], :schema=>false).must_equal [{:on_delete=>:no_action, :on_update=>:no_action, :columns=>[:i], :key=>[:id], :deferrable=>false, :table=>:testfk, :name=>:testfk_i_fkey, :schema=>:public, validated: true, enforced: true}]
  end

  it "should return uuid fields as strings" do
    @db.get(Sequel.cast('550e8400-e29b-41d4-a716-446655440000', :uuid)).must_equal '550e8400-e29b-41d4-a716-446655440000'
  end

  it "should handle inserts with placeholder literal string tables" do
    ds = @db.from(Sequel.lit('?', :testfk))
    ds.delete
    ds.insert(:id=>1)
    ds.select_map(:id).must_equal [1]
  end

  it "should have notice receiver receive notices" do
    a = nil
    Sequel.connect(DB.opts.merge(:notice_receiver=>proc{|r| a = r.result_error_message})){|db| db.do("BEGIN\nRAISE WARNING 'foo';\nEND;")}
    a.must_equal "WARNING:  foo\n"
  end if uses_pg && DB.server_version >= 90000
end

describe "A PostgreSQL database " do
  after do
    DB.drop_table?(:b, :a)
  end

  it "should handle non-ASCII column aliases" do
    s = String.new("\u00E4").force_encoding(DB.get(Sequel.cast('a', :text)).encoding)
    k, v = DB.select(Sequel.as(Sequel.cast(s, :text), s)).first.shift
    k.to_s.must_equal v
  end

  it "should parse foreign keys referencing current table using :reverse option" do
    DB.create_table!(:a) do
      primary_key :id
      Integer :i
      Integer :j
      foreign_key :a_id, :a, :foreign_key_constraint_name=>:a_a
      unique [:i, :j]
    end
    DB.create_table!(:b) do
      foreign_key :a_id, :a, :foreign_key_constraint_name=>:a_a
      Integer :c
      Integer :d
      foreign_key [:c, :d], :a, :key=>[:j, :i], :name=>:a_c_d
    end
    DB.foreign_key_list(:a, :reverse=>true).must_equal [
      {:name=>:a_a, :columns=>[:a_id], :key=>[:id], :on_update=>:no_action, :on_delete=>:no_action, :deferrable=>false, :table=>:a, :schema=>:public, validated: true, enforced: true},
      {:name=>:a_a, :columns=>[:a_id], :key=>[:id], :on_update=>:no_action, :on_delete=>:no_action, :deferrable=>false, :table=>:b, :schema=>:public, validated: true, enforced: true},
      {:name=>:a_c_d, :columns=>[:c, :d], :key=>[:j, :i], :on_update=>:no_action, :on_delete=>:no_action, :deferrable=>false, :table=>:b, :schema=>:public, validated: true, enforced: true}]
  end
end

describe "A PostgreSQL database with domain types" do
  before(:all) do
    @db = DB
    @db << "DROP DOMAIN IF EXISTS positive_number CASCADE"
    @db << "CREATE DOMAIN positive_number AS numeric(10,2) CHECK (VALUE > 0)"
    @db.create_table!(:testfk){positive_number :id, :primary_key=>true}
  end
  after(:all) do
    @db.drop_table?(:testfk)
    @db << "DROP DOMAIN positive_number"
  end

  it "should correctly parse the schema" do
    sch = @db.schema(:testfk, :reload=>true)
    sch.first.last.delete(:domain_oid).must_be_kind_of(Integer)
    sch.first.last[:db_domain_type].must_equal 'positive_number'
  end
end

describe "A PostgreSQL dataset" do
  before(:all) do
    @db = DB
    @d = @db[:test]
    @db.create_table! :test do
      text :name
      integer :value, :index => true
    end
  end
  before do
    @d.delete
  end
  after do
    @db.drop_table?(:atest)
  end
  after(:all) do
    @db.drop_table?(:test)
  end

  it "should support returning limited results with ties" do
    @d.insert(:value => 1)
    @d.insert(:value => 1)
    @d.insert(:value => 2)
    @d.insert(:value => 2)
    @d.order(:value).select(:value).limit(1).select_order_map(:value).must_equal [1]
    @d.order(:value).select(:value).limit(1).with_ties.select_order_map(:value).must_equal [1, 1]
    @d.order(:value).select(:value).limit(2, 1).select_order_map(:value).must_equal [1, 2]
    @d.order(:value).select(:value).limit(2, 1).with_ties.select_order_map(:value).must_equal [1, 2, 2]
    @d.order(:value).select(:value).offset(1).select_order_map(:value).must_equal [1, 2, 2]
    @d.order(:value).select(:value).offset(1).with_ties.select_order_map(:value).must_equal [1, 2, 2]
  end if DB.server_version >= 130000

  it "should support regexps" do
    @d.insert(:name => 'abc', :value => 1)
    @d.insert(:name => 'bcd', :value => 2)
    @d.filter(:name => /bc/).count.must_equal 2
    @d.filter(:name => /^bc/).count.must_equal 1
  end

  it "should support NULLS FIRST and NULLS LAST" do
    @d.insert(:name => 'abc')
    @d.insert(:name => 'bcd')
    @d.insert(:name => 'bcd', :value => 2)
    @d.order(Sequel.asc(:value, :nulls=>:first), :name).select_map(:name).must_equal %w[abc bcd bcd]
    @d.order(Sequel.asc(:value, :nulls=>:last), :name).select_map(:name).must_equal %w[bcd abc bcd]
    @d.order(Sequel.asc(:value, :nulls=>:first), :name).reverse.select_map(:name).must_equal %w[bcd bcd abc]
  end

  it "should support selecting from LATERAL functions" do
    @d.from{[generate_series(1,3,1).as(:a), pow(:a, 2).lateral.as(:b)]}.select_map([:a, :b])== [[1, 1], [2, 4], [3, 9]]
  end if DB.server_version >= 90300

  it "should support ordered-set and hypothetical-set aggregate functions" do
    @d.from{generate_series(1,3,1).as(:a)}.select{(a.sql_number % 2).as(:a)}.from_self.get{mode.function.within_group(:a)}.must_equal 1
  end if DB.server_version >= 90400

  it "should support functions with ordinality" do
    @d.from{generate_series(1,10,3).with_ordinality}.select_map([:generate_series, :ordinality]).must_equal [[1, 1], [4, 2], [7, 3], [10, 4]]
  end if DB.server_version >= 90400

  it "#lock should lock tables and yield if a block is given" do
    @d.lock('EXCLUSIVE'){@d.insert(:name=>'a')}
  end

  it "#lock should raise Error for unsupported lock mode" do
    proc{@d.lock('BAD'){}}.must_raise Sequel::Error
  end

  it 'supports creating tables with UNIQUE NULLS NOT DISTINCT column constraint' do
    @db.create_table!(:atest){Integer :id, unique: {nulls_not_distinct: true}}
    @db[:atest].insert
    @db[:atest].insert(1)
    proc{@db[:atest].insert}.must_raise Sequel::UniqueConstraintViolation
  end if DB.server_version >= 150000

  it 'supports creating tables with UNIQUE NULLS NOT DISTINCT table constraint' do
    @db.create_table!(:atest){Integer :id; unique :id, nulls_not_distinct: true}
    @db[:atest].insert
    @db[:atest].insert(1)
    proc{@db[:atest].insert}.must_raise Sequel::UniqueConstraintViolation
  end if DB.server_version >= 150000

  it 'supports adding UNIQUE NULLS NOT DISTINCT to table' do
    @db.create_table!(:atest){Integer :id}
    @db.alter_table(:atest){add_unique_constraint :id, nulls_not_distinct: true}
    @db[:atest].insert
    @db[:atest].insert(1)
    proc{@db[:atest].insert}.must_raise Sequel::UniqueConstraintViolation
  end if DB.server_version >= 150000

  it 'supports creating tables with PRIMARY KEY WITHOUT OVERLAPS' do
    @db.create_table!(:atest){int4range :id; int4range :t; primary_key [:id, :t], without_overlaps: true}
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(1..5))
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(6..10))
    proc{@db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(9..11))}.must_raise Sequel::Postgres::ExclusionConstraintViolation
  end if DB.server_version >= 180000

  it 'supports creating tables with UNIQUE WITHOUT OVERLAPS' do
    @db.create_table!(:atest){int4range :id; int4range :t; unique [:id, :t], without_overlaps: true}
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(1..5))
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(6..10))
    proc{@db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(9..11))}.must_raise Sequel::Postgres::ExclusionConstraintViolation
  end if DB.server_version >= 180000

  it 'supports adding PRIMARY KEY WITHOUT OVERLAPS to existing tables' do
    @db.create_table!(:atest){int4range :id; int4range :t}
    @db.alter_table(:atest){add_primary_key [:id, :t], without_overlaps: true}
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(1..5))
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(6..10))
    proc{@db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(9..11))}.must_raise Sequel::Postgres::ExclusionConstraintViolation
  end if DB.server_version >= 180000

  it 'supports adding UNIQUE WITHOUT OVERLAPS to existing tables' do
    @db.create_table!(:atest){int4range :id; int4range :t}
    @db.alter_table(:atest){add_unique_constraint [:id, :t], without_overlaps: true}
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(1..5))
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(6..10))
    proc{@db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(9..11))}.must_raise Sequel::Postgres::ExclusionConstraintViolation
  end if DB.server_version >= 180000

  it 'supports :not_null column option with hash value to name constraint' do
    @db.create_table(:atest){Integer :a, :not_null => {name: :atest_a_nn}}
    proc{@db[:atest].insert}.must_raise Sequel::NotNullConstraintViolation
    @db.alter_table(:atest){drop_constraint(:atest_a_nn)}
    @db[:atest].insert
    @db[:atest].select_map(:a).must_equal [nil]
  end if DB.server_version >= 180000

  it 'supports :not_null column option with :no_inherit option' do
    begin
      @db.create_table(:atest){Integer :a, :not_null => {:no_inherit => true}}
      proc{@db[:atest].insert}.must_raise Sequel::NotNullConstraintViolation
      @db.create_table(:atest2, :inherits=>:atest)
      @db[:atest2].insert
      @db[:atest2].select_map(:a).must_equal [nil]
    ensure
      @db.drop_table?(:atest2)
    end
  end if DB.server_version >= 180000

  it 'supports check constraint :no_inherit option' do
    begin
      @db.create_table(:atest){Integer :a; constraint(:no_inherit => true){a > 10}}
      proc{@db[:atest].insert(9)}.must_raise Sequel::CheckConstraintViolation
      @db.create_table(:atest2, :inherits=>:atest)
      @db[:atest2].insert(9)
      @db[:atest2].select_map(:a).must_equal [9]
    ensure
      @db.drop_table?(:atest2)
    end
  end if DB.server_version >= 90200

  it 'supports using PERIOD in composite foreign key constraints' do
    @db.create_table!(:atest) do
      int4range :id
      int4range :t
      int4range :id2
      int4range :t2
      primary_key [:id, :t], without_overlaps: true
      foreign_key [:id2, :t2], :atest, period: true, name: "fk1"
      foreign_key [:id2, :t2], :atest, period: true, name: "fk2", key: [:id, :t]
    end
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(1..5))
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(6..10))
    @db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(16..20), Sequel.pg_range(1..1), Sequel.pg_range(3..8))
    proc{@db[:atest].insert(Sequel.pg_range(1..1), Sequel.pg_range(21..25), Sequel.pg_range(1..1), Sequel.pg_range(9..12))}.must_raise Sequel::ForeignKeyConstraintViolation
  end if DB.server_version >= 180000

  it "should support exclusion constraints when creating or altering tables" do
    @db.create_table!(:atest){Integer :t; exclude [[Sequel.desc(:t, :nulls=>:last), '=']], :using=>:btree, :where=>proc{t > 0}}
    @db[:atest].insert(1)
    @db[:atest].insert(2)
    proc{@db[:atest].insert(2)}.must_raise(Sequel::Postgres::ExclusionConstraintViolation)

    @db.create_table!(:atest){Integer :t}
    @db.alter_table(:atest){add_exclusion_constraint [[:t, '=']], :using=>:btree, :name=>'atest_ex'}
    @db[:atest].insert(1)
    @db[:atest].insert(2)
    proc{@db[:atest].insert(2)}.must_raise(Sequel::Postgres::ExclusionConstraintViolation)
    @db.alter_table(:atest){drop_constraint 'atest_ex'}
  end if DB.server_version >= 90000
  
  it "should support deferrable exclusion constraints" do
    @db.create_table!(:atest){Integer :t; exclude [[Sequel.desc(:t, :nulls=>:last), '=']], :using=>:btree, :where=>proc{t > 0}, :deferrable => true}
    proc do 
      @db.transaction do
        @db[:atest].insert(2)
        @db[:atest].insert(2)
      end
    end.must_raise(Sequel::Postgres::ExclusionConstraintViolation)
  end if DB.server_version >= 90000

  it "should support Database#error_info for getting info hash on the given error" do
    @db.create_table!(:atest){Integer :t; Integer :t2, :null=>false, :default=>1; constraint :f, :t=>0}
    begin
      @db[:atest].insert(1)
    rescue => e
    end
    e.wont_equal nil
    info = @db.error_info(e)
    info[:schema].must_equal 'public'
    info[:table].must_equal 'atest'
    info[:constraint].must_equal 'f'
    info[:column].must_be_nil
    info[:type].must_be_nil

    begin
      @db[:atest].insert(0, nil)
    rescue => e
    end
    e.wont_equal nil
    info = @db.error_info(e.wrapped_exception)
    info[:schema].must_equal 'public'
    info[:table].must_equal 'atest'
    info[:constraint].must_be_nil
    info[:column].must_equal 't2'
    info[:type].must_be_nil
  end if DB.server_version >= 90300 && uses_pg && Object.const_defined?(:PG) && ::PG.const_defined?(:Constants) && ::PG::Constants.const_defined?(:PG_DIAG_SCHEMA_NAME)

  it "should support Database#do for executing anonymous code blocks" do
    @db.drop_table?(:btest)
    @db.do "BEGIN EXECUTE 'CREATE TABLE btest (a INTEGER)'; EXECUTE 'INSERT INTO btest VALUES (1)'; END"
    @db[:btest].select_map(:a).must_equal [1]

    @db.do "BEGIN EXECUTE 'DROP TABLE btest; CREATE TABLE atest (a INTEGER)'; EXECUTE 'INSERT INTO atest VALUES (1)'; END", :language=>:plpgsql
    @db[:atest].select_map(:a).must_equal [1]
  end if DB.server_version >= 90000

  it "should support adding foreign key constraints that are not yet valid, and validating them later" do
    @db.create_table!(:atest){primary_key :id; Integer :fk}
    @db[:atest].insert(1, 5)
    @db.alter_table(:atest){add_foreign_key [:fk], :atest, :not_valid=>true, :name=>:atest_fk}
    @db[:atest].insert(2, 1)
    proc{@db[:atest].insert(3, 4)}.must_raise(Sequel::ForeignKeyConstraintViolation)
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: false, enforced: true}]

    proc{@db.alter_table(:atest){validate_constraint :atest_fk}}.must_raise(Sequel::ForeignKeyConstraintViolation)
    @db[:atest].where(:id=>1).update(:fk=>2)
    @db.alter_table(:atest){validate_constraint :atest_fk}
    @db.alter_table(:atest){validate_constraint :atest_fk}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: true, enforced: true}]
  end if DB.server_version >= 90200

  it "should support adding check constraints that are not yet valid, and validating them later" do
    @db.create_table!(:atest){Integer :a}
    @db[:atest].insert(5)
    @db.alter_table(:atest){add_constraint({:name=>:atest_check, :not_valid=>true}){a >= 10}}
    @db[:atest].insert(10)
    proc{@db[:atest].insert(6)}.must_raise(Sequel::CheckConstraintViolation)

    proc{@db.alter_table(:atest){validate_constraint :atest_check}}.must_raise(Sequel::CheckConstraintViolation, Sequel::DatabaseError)
    @db[:atest].where{a < 10}.update(:a=>Sequel.+(:a, 10))
    @db.alter_table(:atest){validate_constraint :atest_check}
    @db.alter_table(:atest){validate_constraint :atest_check}
  end if DB.server_version >= 90200

  it "should support creating columns with foreign key constraints that are not enforced" do
    @db.create_table!(:atest){primary_key :id; foreign_key :fk, :atest, :not_enforced=>true, :foreign_key_constraint_name=>:atest_fk}
    @db[:atest].insert(1, 5)
    @db[:atest].insert(3, 4)
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: false, enforced: false}]
  end if DB.server_version >= 180000

  it "should support adding foreign key constraints that are not enforced" do
    @db.create_table!(:atest){primary_key :id; Integer :fk}
    @db[:atest].insert(1, 5)
    @db.alter_table(:atest){add_foreign_key [:fk], :atest, :not_enforced=>true, :name=>:atest_fk}
    @db[:atest].insert(3, 4)
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: false, enforced: false}]
  end if DB.server_version >= 180000

  it "should support altering enforcement of foreign key constraints" do
    @db.create_table!(:atest){primary_key :id; Integer :fk}
    @db.alter_table(:atest){add_foreign_key [:fk], :atest, :not_enforced=>true, :name=>:atest_fk}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: false, enforced: false}]
    @db.alter_table(:atest){alter_constraint(:atest_fk, :enforced=>true)}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: true, enforced: true}]
    @db.alter_table(:atest){alter_constraint(:atest_fk, :enforced=>false)}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: false, enforced: false}]
  end if DB.server_version >= 180000

  it "should support altering deferrability of foreign key constraints" do
    @db.create_table!(:atest){primary_key :id; Integer :fk}
    @db.alter_table(:atest){add_foreign_key [:fk], :atest, :name=>:atest_fk}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: true, enforced: true}]
    @db.alter_table(:atest){alter_constraint(:atest_fk, :deferrable=>true)}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: true, table: :atest, schema: :public, validated: true, enforced: true}]
    @db.alter_table(:atest){alter_constraint(:atest_fk, :deferrable=>false)}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: true, enforced: true}]

    # Deferrable constraints that are initialially immediate are reported as not deferrable,
    # because they are not deferred unless SET CONSTRAINTS is used. If this actually 
    # causes an issue, we can add an :initially_immediate key so the information can be
    # tracked separately.
    @db.alter_table(:atest){alter_constraint(:atest_fk, :deferrable=>:immediate)}
    @db.foreign_key_list(:atest).must_equal [{name: :atest_fk, columns: [:fk], key: [:id], on_update: :no_action, on_delete: :no_action, deferrable: false, table: :atest, schema: :public, validated: true, enforced: true}]
  end if DB.server_version >= 90400

  it "should support adding check constraints that are not enforced" do
    @db.create_table!(:atest){Integer :a}
    @db[:atest].insert(5)
    @db.alter_table(:atest){add_constraint({:name=>:atest_check, :not_enforced=>true}){a >= 10}}
    @db[:atest].insert(6)
    @db.check_constraints(:atest).must_equal(atest_check: {definition: "CHECK ((a >= 10)) NOT ENFORCED", columns: [:a], validated: false, enforced: false}) 
  end if DB.server_version >= 180000

  it "should support altering inheritability of NOT NULL constraints" do
    @db.create_table(:atest){Integer :fk, :not_null => {:name => :atest_nn}}
    @db.alter_table(:atest){alter_constraint(:atest_nn, :inherit=>true)}
    @db.alter_table(:atest){alter_constraint(:atest_nn, :inherit=>false)}
  end if DB.server_version >= 180000

  it "should support :using when altering a column's type" do
    @db.create_table!(:atest){Integer :t}
    @db[:atest].insert(1262404000)
    @db.alter_table(:atest){set_column_type :t, Time, :using=>Sequel.cast('epoch', Time) + Sequel.cast('1 second', :interval) * :t}
    @db[:atest].get(Sequel.extract(:year, :t)).must_equal 2010
  end

  it "should support :using with a string when altering a column's type" do
    @db.create_table!(:atest){Integer :t}
    @db[:atest].insert(1262304000)
    @db.alter_table(:atest){set_column_type :t, Time, :using=>"'epoch'::timestamp + '1 second'::interval * t"}
    @db[:atest].get(Sequel.extract(:year, :t)).must_equal 2010
  end

  it "should have #transaction support various types of synchronous options" do
    @db.transaction(:synchronous=>:on){}
    @db.transaction(:synchronous=>true){}
    @db.transaction(:synchronous=>:off){}
    @db.transaction(:synchronous=>false){}

    @db.transaction(:synchronous=>nil){}
    if @db.server_version >= 90100
      @db.transaction(:synchronous=>:local){}

      if @db.server_version >= 90200
        @db.transaction(:synchronous=>:remote_write){}
      end
    end
  end

  it "should have #transaction support read only transactions" do
    @db.transaction(:read_only=>true){}
    @db.transaction(:read_only=>false){}
    @db.transaction(:isolation=>:serializable, :read_only=>true){}
    @db.transaction(:isolation=>:serializable, :read_only=>false){}
  end

  it "should have #transaction support deferrable transactions" do
    @db.transaction(:deferrable=>true){}
    @db.transaction(:deferrable=>false){}
    @db.transaction(:deferrable=>true, :read_only=>true){}
    @db.transaction(:deferrable=>false, :read_only=>false){}
    @db.transaction(:isolation=>:serializable, :deferrable=>true, :read_only=>true){}
    @db.transaction(:isolation=>:serializable, :deferrable=>false, :read_only=>false){}
  end if DB.server_version >= 90100

  it "should support parsing partial indexes with :include_partial option" do
    @db.add_index :test, [:name, :value], :where=>(Sequel[:value] > 10), :name=>:tnv_partial
    @db.indexes(:test)[:tnv_partial].must_be_nil
    @db.indexes(:test, :include_partial=>true)[:tnv_partial].must_equal(:columns=>[:name, :value], :unique=>false, :deferrable=>nil)
  end

  it "should support creating indexes concurrently" do
    @db.add_index :test, [:name, :value], :concurrently=>true, :name=>'tnv0'
  end

  it "should support dropping indexes only if they already exist" do
    proc{@db.drop_index :test, [:name, :value], :name=>'tnv1'}.must_raise Sequel::DatabaseError
    @db.drop_index :test, [:name, :value], :if_exists=>true, :name=>'tnv1'
    @db.add_index :test, [:name, :value], :name=>'tnv1'
    @db.drop_index :test, [:name, :value], :if_exists=>true, :name=>'tnv1'
  end

  it "should support CASCADE when dropping indexes" do
    @db.add_index :test, [:name, :value], :name=>'tnv2', :unique=>true
    @db.create_table(:atest){text :name; integer :value; foreign_key [:name, :value], :test, :key=>[:name, :value]}
    @db.foreign_key_list(:atest).length.must_equal 1
    @db.drop_index :test, [:name, :value], :cascade=>true, :name=>'tnv2'
    @db.foreign_key_list(:atest).length.must_equal 0
  end

  it "should support dropping indexes concurrently" do
    @db.add_index :test, [:name, :value], :name=>'tnv2'
    @db.drop_index :test, [:name, :value], :concurrently=>true, :name=>'tnv2'
  end if DB.server_version >= 90200

  it "should support creating indexes only if they do not exist" do
    @db.add_index :test, [:name, :value], :name=>'tnv3'
    proc{@db.add_index :test, [:name, :value], :name=>'tnv3'}.must_raise Sequel::DatabaseError
    @db.add_index :test, [:name, :value], :if_not_exists=>true, :name=>'tnv3'
  end if DB.server_version >= 90500

  it "should support specifying whether NULLS are distinct in unique indexes" do
    @db.create_table(:atest){Integer :a}
    @db.add_index :atest, :a, :nulls_distinct=>true, :unique=>true
    @db[:atest].insert
    @db[:atest].insert
    @db[:atest].count.must_equal 2

    @db.create_table!(:atest){Integer :a}
    @db.add_index :atest, :a, :nulls_distinct=>false, :unique=>true
    @db[:atest].insert
    proc{@db[:atest].insert}.must_raise Sequel::DatabaseError
  end if DB.server_version >= 150000

  it "should support including columns in indexes" do
    @db.create_table(:atest){Integer :a; Integer :b; Integer :c}
    @db.add_index :atest, :a, :include=>[:b, :c]
    @db.add_index :atest, :b, :include=>:a
  end if DB.server_version >= 110000

  it "should support specifying tablespaces for tables" do
    @db.create_table(:atest, :tablespace=>:pg_default){Integer :a}
  end

  it "should support specifying tablespaces for indexes" do
    @db.create_table(:atest){Integer :a}
    @db.add_index :atest, :a, :tablespace=>:pg_default
  end

  it "#lock should lock table if inside a transaction" do
    @db.transaction{@d.lock('EXCLUSIVE'); @d.insert(:name=>'a')}
  end

  it "#lock should return nil" do
    @d.lock('EXCLUSIVE'){@d.insert(:name=>'a')}.must_be_nil
    @db.transaction{@d.lock('EXCLUSIVE').must_be_nil; @d.insert(:name=>'a')}
  end

  it "should raise an error if attempting to update a joined dataset with a single FROM table" do
    proc{@db[:test].join(:test, [:name]).update(:name=>'a')}.must_raise(Sequel::Error, 'Need multiple FROM tables if updating/deleting a dataset with JOINs')
  end

  it "should truncate with options" do
    @d.insert( :name => 'abc', :value => 1)
    @d.count.must_equal 1
    @d.truncate(:cascade => true)
    @d.count.must_equal 0
    @d.insert( :name => 'abc', :value => 1)
    @d.truncate(:cascade => true, :only=>true, :restart=>true)
    @d.count.must_equal 0
  end

  it "should truncate multiple tables at once" do
    tables = [:test, :test]
    tables.each{|t| @d.from(t).insert}
    @d.from(:test, :test).truncate
    tables.each{|t| @d.from(t).count.must_equal 0}
  end

  it "should not allow truncate for grouped or joined datasets" do
    proc{@d.from(:test).cross_join(:test).truncate}.must_raise Sequel::InvalidOperation
    proc{@d.from(:test).group(:test).truncate}.must_raise Sequel::InvalidOperation
  end

  it "should raise when attempting to insert with 0 or multiple tables" do
    proc{@d.from(:test, :test).insert}.must_raise Sequel::InvalidOperation
    proc{@d.from.insert}.must_raise Sequel::Error
  end
end

describe "Dataset#distinct" do
  before do
    @db = DB
    @db.create_table!(:a) do
      Integer :a
      Integer :b
    end
    @ds = @db[:a]
  end
  after do
    @db.drop_table?(:a)
  end

  it "#distinct with arguments should return results distinct on those arguments" do
    @ds.insert(20, 10)
    @ds.insert(30, 10)
    @ds.order(:b, :a).distinct.map(:a).must_equal [20, 30]
    @ds.order(:b, Sequel.desc(:a)).distinct.map(:a).must_equal [30, 20]
    @ds.order(:b, :a).distinct(:b).map(:a).must_equal [20]
    @ds.order(:b, Sequel.desc(:a)).distinct(:b).map(:a).must_equal [30]
  end
end

if DB.pool.respond_to?(:max_size) and DB.pool.max_size > 1
  update_meths = [:for_update]
  share_meths = [:for_share]

  if DB.server_version >= 90300
    update_meths << :for_no_key_update
    share_meths << :for_key_share
  end

  describe "Dataset locking support" do
    before do
      @db = DB.create_table!(:items) do
        primary_key :id
        Integer :number
        String :name
      end
      @ds = DB[:items]
    end
    after do
      DB.drop_table?(:items)
      DB.disconnect
    end

    update_meths.each do |meth|
      it "##{meth} should lock rows for updating" do
        ds = @ds.send(meth)
        ds.send(meth).must_be_same_as ds
        @ds.insert(:number=>20)
        c, t = nil, nil
        q = Queue.new
        DB.transaction do
          ds.first(:id=>1)
          t = Thread.new do
            DB.transaction do
              q.push nil
              @ds.filter(:id=>1).update(:name=>'Jim')
              c = @ds.first(:id=>1)
              q.push nil
            end
          end
          q.pop
          @ds.filter(:id=>1).update(:number=>30)
        end
        q.pop
        t.join
        c.must_equal(:id=>1, :number=>30, :name=>'Jim')
      end
    end

    share_meths.each do |meth|
      it "##{meth} should not lock rows for updating" do
        ds = @ds.send(meth)
        ds.send(meth).must_be_same_as ds
        @ds.insert(:number=>20)
        c, t = nil
        q = Queue.new
        DB.transaction do
          ds.first(:id=>1)
          t = Thread.new do
            DB.transaction do
              c = ds.filter(:id=>1).first
              q.push nil
            end
          end
          q.pop
          @ds.filter(:id=>1).update(:name=>'Jim')
          c.must_equal(:id=>1, :number=>20, :name=>nil)
        end
        t.join
      end
    end
  end
end

describe "A PostgreSQL dataset with a timestamp field" do
  before(:all) do
    @db = DB
    @db.create_table! :test3 do
      Date :date
      DateTime :time
    end
    @d = @db[:test3]
    if @db.adapter_scheme == :postgres
      @db.convert_infinite_timestamps.must_equal false unless ENV['SEQUEL_PG_AUTO_PARAMETERIZE']
      @db.convert_infinite_timestamps = false
      @db.convert_infinite_timestamps = true
      @db.convert_infinite_timestamps = false
    else
      @db.extension :pg_extended_date_support
    end
  end
  before do
    @d.delete
  end
  after do
    @db.convert_infinite_timestamps = false
    Sequel.datetime_class = Time
    Sequel::SQLTime.date = nil
    Sequel.default_timezone = nil
  end
  after(:all) do
    @db.drop_table?(:test3)
  end

  it "should store milliseconds in time fields for Time objects" do
    t = Time.now
    @d.insert(:time=>t)
    t2 = @d.get(:time)
    @d.literal(t2).must_equal @d.literal(t)
    t2.strftime('%Y-%m-%d %H:%M:%S').must_equal t.strftime('%Y-%m-%d %H:%M:%S')
    (t2.is_a?(Time) ? t2.usec : t2.strftime('%N').to_i/1000).must_equal t.usec
  end

  it "should store milliseconds in time fields for DateTime objects" do
    t = DateTime.now
    @d.insert(:time=>t)
    t2 = @d.get(:time)
    @d.literal(t2).must_equal @d.literal(t)
    t2.strftime('%Y-%m-%d %H:%M:%S').must_equal t.strftime('%Y-%m-%d %H:%M:%S')
    (t2.is_a?(Time) ? t2.usec : t2.strftime('%N').to_i/1000).must_equal t.strftime('%N').to_i/1000
  end

  it "should respect SQLTime.date setting for time columns" do
    Sequel::SQLTime.date = Time.local(2000, 1, 2)
    d = Sequel::SQLTime.create(10, 11, 12)
    @db.get(Sequel.cast(d, :time)).must_equal d
    @db.get(Sequel.cast(d, :timetz)).must_equal d
  end

  it "should respect Sequel.application_timezone for time columns" do
    d = Sequel::SQLTime.create(10, 11, 12)
    Sequel.application_timezone = :local
    @db.get(Sequel.cast(d, :time)).utc_offset.must_equal Time.now.utc_offset
    @db.get(Sequel.cast(d, :timetz)).utc_offset.must_equal Time.now.utc_offset
    Sequel.application_timezone = :utc
    @db.get(Sequel.cast(d, :time)).utc_offset.must_equal 0
    @db.get(Sequel.cast(d, :timetz)).utc_offset.must_equal 0
  end

  it "should handle parsing dates and timestamps in with 1, 2, and 3 digit years" do
    [1, 10, 100, -2, -20, -200].each do |year|
      d = Date.new(year, 2, 3)
      @db.get(Sequel.cast(d, Date)).must_equal d
      begin
        Sequel.default_timezone = :utc
        d = Time.utc(year, 2, 3, 10, 11, 12)
        @db.get(Sequel.cast(d, Time)).must_equal d
        Sequel.datetime_class = DateTime
        d = DateTime.new(year, 2, 3, 10, 11, 12)
        @db.get(Sequel.cast(d, Time)).must_equal d
      ensure
        Sequel.datetime_class = Time
        Sequel.default_timezone = nil
      end
    end
  end

  it "should handle parsing dates and timestamps in the distant future" do
    d = Date.new(5874896, 2, 3)
    @db.get(Sequel.cast(d, Date)).must_equal d

    d = Time.local(294275, 2, 3, 10, 11, 12)
    @db.get(Sequel.cast(d, Time)).must_equal d

    Sequel.datetime_class = DateTime
    d = DateTime.new(294275, 2, 3, 10, 11, 12)
    @db.get(Sequel.cast(d, Time)).must_equal d
  end

  it "should handle BC times and dates" do
    d = Date.new(-1234, 2, 3)
    @db.get(Sequel.cast(d, Date)).must_equal d

    Sequel.default_timezone = :utc
    t = Time.at(-100000000000).utc + 0.5
    @db.get(Sequel.cast(t, Time)).must_equal t
    @db.dataset.extension(:pg_timestamptz).get(Sequel.cast(t, :timestamptz)).must_equal t

    Sequel.datetime_class = DateTime
    dt = DateTime.new(-1234, 2, 3, 10, 20, Rational(30, 20))
    @db.get(Sequel.cast(dt, DateTime)).must_equal dt
    @db.dataset.extension(:pg_timestamptz).get(Sequel.cast(dt, :timestamptz)).must_equal dt
  end

  it "should handle BC times and dates in bound variables" do
    d = Date.new(-1234, 2, 3)
    @db.select(Sequel.cast(:$d, Date)).call(:single_value, :d=>d).must_equal d

    Sequel.default_timezone = :utc
    t = Time.at(-100000000000).utc + 0.5
    @db.select(Sequel.cast(:$t, Time)).call(:single_value, :t=>t).must_equal t
    @db.select(Sequel.cast(:$t, :timestamptz)).call(:single_value, :t=>t).must_equal t

    Sequel.datetime_class = DateTime
    dt = DateTime.new(-1234, 2, 3, 10, 20, Rational(30, 20))
    @db.select(Sequel.cast(:$dt, DateTime)).call(:single_value, :dt=>dt).must_equal dt
    @db.select(Sequel.cast(:$dt, :timestamptz)).call(:single_value, :dt=>dt).must_equal dt
  end if uses_pg_or_jdbc 

  it "should handle infinite timestamps if convert_infinite_timestamps is set" do
    @d.insert(:time=>Sequel.cast('infinity', DateTime))
    @db.convert_infinite_timestamps = :nil
    @db[:test3].get(:time).must_be_nil
    @db.convert_infinite_timestamps = :string
    @db[:test3].get(:time).must_equal 'infinity'
    @db.convert_infinite_timestamps = :float
    @db[:test3].get(:time).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = 'nil'
    @db[:test3].get(:time).must_be_nil
    @db.convert_infinite_timestamps = 'string'
    @db[:test3].get(:time).must_equal 'infinity'
    @db.convert_infinite_timestamps = 'date'
    @db[:test3].get(:time).must_equal Date::Infinity.new
    @db.convert_infinite_timestamps = 'float'
    @db[:test3].get(:time).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = 't'
    @db[:test3].get(:time).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = true
    @db[:test3].get(:time).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = 'f'
    proc{@db[:test3].get(:time)}.must_raise ArgumentError, Sequel::InvalidValue
    @db.convert_infinite_timestamps = nil
    proc{@db[:test3].get(:time)}.must_raise ArgumentError, Sequel::InvalidValue
    @db.convert_infinite_timestamps = false
    proc{@db[:test3].get(:time)}.must_raise ArgumentError, Sequel::InvalidValue

    @d.update(:time=>Sequel.cast('-infinity', DateTime))
    @db.convert_infinite_timestamps = :nil
    @db[:test3].get(:time).must_be_nil
    @db.convert_infinite_timestamps = :string
    @db[:test3].get(:time).must_equal '-infinity'
    @db.convert_infinite_timestamps = :date
    @db[:test3].get(:time).must_equal(-Date::Infinity.new)
    @db.convert_infinite_timestamps = :float
    @db[:test3].get(:time).must_equal(-1.0/0.0)
  end

  it "should handle infinite dates if convert_infinite_timestamps is set" do
    @d.insert(:time=>Sequel.cast('infinity', DateTime))
    @db.convert_infinite_timestamps = :nil
    @db[:test3].get(Sequel.cast(:time, Date)).must_be_nil
    @db.convert_infinite_timestamps = :string
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal 'infinity'
    @db.convert_infinite_timestamps = :float
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = 'nil'
    @db[:test3].get(Sequel.cast(:time, Date)).must_be_nil
    @db.convert_infinite_timestamps = 'string'
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal 'infinity'
    @db.convert_infinite_timestamps = 'float'
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = 't'
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = true
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal 1.0/0.0
    @db.convert_infinite_timestamps = 'f'
    proc{@db[:test3].get(Sequel.cast(:time, Date))}.must_raise ArgumentError, Sequel::InvalidValue
    @db.convert_infinite_timestamps = nil
    proc{@db[:test3].get(Sequel.cast(:time, Date))}.must_raise ArgumentError, Sequel::InvalidValue
    @db.convert_infinite_timestamps = false
    proc{@db[:test3].get(Sequel.cast(:time, Date))}.must_raise ArgumentError, Sequel::InvalidValue

    @d.update(:time=>Sequel.cast('-infinity', DateTime))
    @db.convert_infinite_timestamps = :nil
    @db[:test3].get(Sequel.cast(:time, Date)).must_be_nil
    @db.convert_infinite_timestamps = :string
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal '-infinity'
    @db.convert_infinite_timestamps = :float
    @db[:test3].get(Sequel.cast(:time, Date)).must_equal(-1.0/0.0)
  end

  it "should handle conversions from infinite strings/floats in models" do
    c = Class.new(Sequel::Model(:test3))
    @db.convert_infinite_timestamps = :float
    c.new(:time=>'infinity').time.must_equal 'infinity'
    c.new(:time=>'-infinity').time.must_equal '-infinity'
    c.new(:time=>1.0/0.0).time.must_equal 1.0/0.0
    c.new(:time=>-1.0/0.0).time.must_equal(-1.0/0.0)
  end

  it "should handle infinite dates if convert_infinite_timestamps is set" do
    @d.insert(:date=>Sequel.cast('infinity', Date))
    @db.convert_infinite_timestamps = :nil
    @db[:test3].get(:date).must_be_nil
    @db.convert_infinite_timestamps = :string
    @db[:test3].get(:date).must_equal 'infinity'
    @db.convert_infinite_timestamps = :float
    @db[:test3].get(:date).must_equal 1.0/0.0

    @d.update(:date=>Sequel.cast('-infinity', :timestamp))
    @db.convert_infinite_timestamps = :nil
    @db[:test3].get(:date).must_be_nil
    @db.convert_infinite_timestamps = :string
    @db[:test3].get(:date).must_equal '-infinity'
    @db.convert_infinite_timestamps = :float
    @db[:test3].get(:date).must_equal(-1.0/0.0)
  end

  it "should handle conversions from infinite strings/floats in models" do
    c = Class.new(Sequel::Model(:test3))
    @db.convert_infinite_timestamps = :float
    c.new(:date=>'infinity').date.must_equal 'infinity'
    c.new(:date=>'-infinity').date.must_equal '-infinity'
    c.new(:date=>1.0/0.0).date.must_equal 1.0/0.0
    c.new(:date=>-1.0/0.0).date.must_equal(-1.0/0.0)
  end

  it "explain and analyze should not raise errors" do
    ds = @db[:test3]
    ds.explain
    ds.analyze

    ds = ds.where{date > Date.today}
    ds.explain
    ds.analyze

    next if @db.server_version < 90000
    ds.explain(:costs=>false)
    require 'yaml'
    res = YAML.load(ds.explain(:analyze=>true, :verbose=>true, :buffers=>true, :format=>:yaml))
    res.must_be_kind_of Array
    res[0].must_be_kind_of Hash
    res.count.must_equal 1

    next if @db.server_version < 92000
    res = ds.explain(:analyze=>true, :timing=>true, format: :json)
    res.must_be_kind_of Array
    res[0].must_be_kind_of Hash
    res.count.must_equal 1

    next if @db.server_version < 100000
    res = ds.explain(:analyze=>true, :summary=>true, format: :xml)
    if res.is_a?(String) # could be Java::OrgPostgresqlJdbc::PgSQLXML when using jdbc adapter
      res.start_with?("<").must_equal true
      res.end_with?(">").must_equal true
    end

    next if @db.server_version < 120000
    ds.explain(:settings=>true)

    next if @db.server_version < 160000
    ds.explain(:generic_plan=>true)

    next if @db.server_version < 170000
    ds.explain(:generic_plan=>true, :costs=>false)
    ds.explain(:verbose=>true, :settings=>true, :buffers=>true, :summary=>true, :memory=>true)
    ds.explain(:analyze=>true, :serialize=>:text, :memory=>true, :wal=>true, :timing=>true, :format=>:text)
    ds.explain(:analyze=>true, :serialize=>:binary)
    ds.explain(:analyze=>true, :serialize=>:none)

    proc{ds.explain(:format=>:bad)}.must_raise Sequel::Error
  end

  it "#locks should be a dataset returning database locks " do
    @db.locks.must_be_kind_of(Sequel::Dataset)
    @db.locks.all.must_be_kind_of(Array)
  end
end

describe "A PostgreSQL database" do
  before do
    @db = DB
    @db.create_table! :test2 do
      text :name
      integer :value
    end
  end
  after do
    @db.drop_table?(:test2)
  end

  it "should support column operations" do
    @db.create_table!(:test2){text :name; integer :value}
    @db[:test2].insert({})
    @db[:test2].columns.must_equal [:name, :value]

    @db.add_column :test2, :xyz, :text, :default => '000'
    @db[:test2].columns.must_equal [:name, :value, :xyz]
    @db[:test2].insert(:name => 'mmm', :value => 111)
    @db[:test2].first[:xyz].must_equal '000'

    @db[:test2].columns.must_equal [:name, :value, :xyz]
    @db.drop_column :test2, :xyz

    @db[:test2].columns.must_equal [:name, :value]

    @db[:test2].delete
    @db.add_column :test2, :xyz, :text, :default => '000'
    @db[:test2].insert(:name => 'mmm', :value => 111, :xyz => 'qqqq')

    @db[:test2].columns.must_equal [:name, :value, :xyz]
    @db.rename_column :test2, :xyz, :zyx
    @db[:test2].columns.must_equal [:name, :value, :zyx]
    @db[:test2].first[:zyx].must_equal 'qqqq'

    @db.add_column :test2, :xyz, :float
    @db[:test2].delete
    @db[:test2].insert(:name => 'mmm', :value => 111, :xyz => 56.78)
    @db.set_column_type :test2, :xyz, :integer

    @db[:test2].first[:xyz].must_equal 57
  end
end

describe "A PostgreSQL database" do
  before do
    @db = DB
    @db.drop_table?(:posts)
  end
  after do
    @db.drop_table?(:posts)
  end

  it "should support resetting the primary key sequence" do
    @db.create_table(:posts){primary_key :a}
    @db[:posts].insert(:a=>20).must_equal 20
    @db[:posts].insert.must_equal 1
    @db[:posts].insert.must_equal 2
    @db[:posts].insert(:a=>10).must_equal 10
    @db.reset_primary_key_sequence(:posts).must_equal 21
    @db[:posts].insert.must_equal 21
    @db[:posts].order(:a).map(:a).must_equal [1, 2, 10, 20, 21]
  end
    
  it "should support specifying Integer/Bignum types in primary keys and have them be auto incrementing" do
    @db.create_table(:posts){primary_key :a, :type=>Integer}
    @db[:posts].insert.must_equal 1
    @db[:posts].insert.must_equal 2
    @db.create_table!(:posts){primary_key :a, :type=>:Bignum}
    @db[:posts].insert.must_equal 1
    @db[:posts].insert.must_equal 2
  end

  it "should not raise an error if attempting to resetting the primary key sequence for a table without a primary key" do
    @db.create_table(:posts){Integer :a}
    @db.reset_primary_key_sequence(:posts).must_be_nil
  end

  it "should support opclass specification" do
    @db.create_table(:posts){text :title; text :body; integer :user_id; index(:user_id, :opclass => :int4_ops, :type => :btree)}
    proc{@db.create_table(:posts){text :title; text :body; integer :user_id; index(:user_id, :opclass => :bogus_opclass, :type => :btree)}}.must_raise Sequel::DatabaseError
  end

  it "should support fulltext indexes and searching" do
    @db.create_table(:posts){text :title; text :body; full_text_index [:title, :body]; full_text_index :title, :language => 'french', :index_type=>:gist}

    @db[:posts].insert(:title=>'ruby rails', :body=>'yowsa')
    @db[:posts].insert(:title=>'sequel', :body=>'ruby')
    @db[:posts].insert(:title=>'ruby scooby', :body=>'x')

    @db[:posts].full_text_search(:title, 'rails').all.must_equal [{:title=>'ruby rails', :body=>'yowsa'}]
    @db[:posts].full_text_search(:title, 'rails', :headline=>true).all.must_equal [{:title=>'ruby rails', :body=>'yowsa', :headline=>'ruby <b>rails</b>'}]
    @db[:posts].full_text_search([:title, :body], ['yowsa', 'rails']).all.must_equal [:title=>'ruby rails', :body=>'yowsa']
    @db[:posts].full_text_search(:title, 'scooby', :language => 'french').all.must_equal [{:title=>'ruby scooby', :body=>'x'}]

    @db[:posts].full_text_search(:title, :$n).call(:select, :n=>'rails').must_equal [{:title=>'ruby rails', :body=>'yowsa'}]
    @db[:posts].full_text_search(:title, :$n).prepare(:select, :fts_select).call(:n=>'rails').must_equal [{:title=>'ruby rails', :body=>'yowsa'}]

    @db[:posts].insert(:title=>'jruby rubinius ruby maglev mri iron')
    @db[:posts].insert(:title=>'ruby jruby maglev mri rubinius iron')
    @db[:posts].full_text_search(:title, 'rubinius ruby', :phrase=>true).select_order_map(:title).must_equal ['jruby rubinius ruby maglev mri iron']
    @db[:posts].full_text_search(:title, 'jruby maglev', :phrase=>true).select_order_map(:title).must_equal ['ruby jruby maglev mri rubinius iron']
    @db[:posts].full_text_search(:title, 'rubinius ruby', :plain=>true).select_order_map(:title).must_equal ['jruby rubinius ruby maglev mri iron', 'ruby jruby maglev mri rubinius iron']
    @db[:posts].full_text_search(:title, 'jruby maglev', :plain=>true).select_order_map(:title).must_equal ['jruby rubinius ruby maglev mri iron', 'ruby jruby maglev mri rubinius iron']

    if DB.server_version >= 90600
      @db[:posts].full_text_search(:title, 'rubinius ruby', :to_tsquery=>:phrase).select_order_map(:title).must_equal ['jruby rubinius ruby maglev mri iron']
      @db[:posts].full_text_search(:title, 'jruby maglev', :to_tsquery=>:phrase).select_order_map(:title).must_equal ['ruby jruby maglev mri rubinius iron']
    end

    if DB.server_version >= 110000
      @db[:posts].full_text_search(:title, 'rails ruby', :to_tsquery=>:websearch).select_order_map(:title).must_equal ["ruby rails"]
      @db[:posts].full_text_search(:title, 'rubinius jruby', :to_tsquery=>:websearch).select_order_map(:title).must_equal ['jruby rubinius ruby maglev mri iron', 'ruby jruby maglev mri rubinius iron']
    end

    @db[:posts].full_text_search(Sequel.function(:to_tsvector, 'simple', :title), 'rails', :tsvector=>true).all.must_equal [{:title=>'ruby rails', :body=>'yowsa'}]
    @db[:posts].full_text_search(:title, Sequel.function(:to_tsquery, 'simple', 'rails'), :tsquery=>true).all.must_equal [{:title=>'ruby rails', :body=>'yowsa'}]
    proc{@db[:posts].full_text_search(Sequel.function(:to_tsvector, 'simple', :title), 'rubinius ruby', :tsvector=>true, :phrase=>true)}.must_raise(Sequel::Error)
    proc{@db[:posts].full_text_search(:title, Sequel.function(:to_tsquery, 'simple', 'rails'), :tsquery=>true, :phrase=>true)}.must_raise(Sequel::Error)

    @db[:posts].delete
    t1 = "bork " * 1000 + "ruby sequel"
    t2 = "ruby sequel " * 1000
    @db[:posts].insert(:title=>t1)
    @db[:posts].insert(:title=>t2)
    @db[:posts].full_text_search(:title, 'ruby & sequel', :rank=>true).select_map(:title).must_equal [t2, t1]
  end

  it "should support spatial indexes" do
    @db.create_table(:posts){box :geom; spatial_index [:geom]}
  end

  it "should support indexes with index type" do
    @db.create_table(:posts){box :geom; index :geom, :type => 'gist'}
  end

  it "should support unique indexes with index type" do
    @db.create_table(:posts){varchar :title, :size => 5; index :title, :type => 'btree', :unique => true, :name=>:post_index_foo}
    @db.indexes(:posts).length.must_equal 1
    @db.indexes(:posts)[:post_index_foo][:unique].must_equal true
  end

  it "should support partial indexes" do
    @db.create_table(:posts){varchar :title, :size => 5; index :title, :where => {:title => '5'}}
  end

  it "should support identifiers for table names when creating indexes" do
    @db.create_table(Sequel::SQL::Identifier.new(:posts)){varchar :title, :size => 5; index :title}
    @db.indexes(:posts).length.must_equal 1
  end

  it "should support renaming tables" do
    @db.create_table!(:posts1){primary_key :a}
    @db.rename_table(:posts1, :posts)
  end

  it "should support :using_index option when adding a UNIQUE constraint" do
    @db.create_table(:posts) do
      Integer :i
      index :i, :name=>:posts_i_uidx, :unique=>true
    end

    @db.alter_table(:posts) do
      add_unique_constraint :i, :using_index=>:posts_i_uidx, :name=>"posts_ukey"
    end
  end if DB.server_version >= 90100

  it "should support :using_index option when adding a PRIMARY KEY constraint" do
    @db.create_table(:posts) do
      Integer :i
      index :i, :name=>:posts_i_uidx, :unique=>true
    end

    @db.alter_table(:posts) do
      add_primary_key [:i], :using_index=>:posts_i_uidx
    end
  end if DB.server_version >= 90100

  it "should adding a column only if it does not already exist" do
    @db.create_table(:posts){Integer :a}
    @db.alter_table(:posts){add_column :b, Integer}
    @db.alter_table(:posts){add_column :b, Integer, :if_not_exists=>true}
    proc{@db.alter_table(:posts){add_column :b, Integer}}.must_raise Sequel::DatabaseError
  end if DB.server_version >= 90600
end

describe "Sequel::Postgres::Database" do
  before do
    @db = DB
    @db.create_table!(:posts){Integer :a}
  end
  after do
    @db.run("DROP PROCEDURE test_procedure_posts(#{@args || "int, int"})")
    @db.drop_table?(:posts)
  end

  it "#call_procedure should call a procedure that returns a row" do
    @db.run <<SQL
CREATE OR REPLACE PROCEDURE test_procedure_posts(inout a int, inout b int)
LANGUAGE SQL
AS $$
INSERT INTO posts VALUES (a) RETURNING *;
INSERT INTO posts VALUES (a * 2) RETURNING *;
SELECT max(posts.a), min(posts.a) FROM posts;
$$;
SQL
    @db.call_procedure(:test_procedure_posts, 1, nil).must_equal(:a=>2, :b=>1)
    @db.call_procedure(:test_procedure_posts, 3, nil).must_equal(:a=>6, :b=>1)
  end

  # Remove after release of pg 1.3.5
  skip_due_to_pg_bug = defined?(Sequel::Postgres::USES_PG) && 
    Sequel::Postgres::USES_PG &&
    DB.respond_to?(:stream_all_queries) &&
    DB.stream_all_queries &&
    defined?(PG::VERSION) &&
    PG::VERSION == '1.3.4'

  it "#call_procedure should call a procedure without arguments" do
    @args = ''
    @db.run <<SQL
CREATE OR REPLACE PROCEDURE test_procedure_posts()
LANGUAGE SQL
AS $$
INSERT INTO posts VALUES (1) RETURNING *;
INSERT INTO posts VALUES (2) RETURNING *;
SELECT max(posts.a), min(posts.a) FROM posts;
$$;
SQL
    @db.call_procedure(:test_procedure_posts).must_be_nil
    @db[:posts].select_order_map(:a).must_equal [1, 2]
  end unless skip_due_to_pg_bug

  it "#call_procedure should call a procedure with output parameters" do
    @db.run <<SQL
CREATE OR REPLACE PROCEDURE test_procedure_posts(out a int, out b int)
LANGUAGE SQL
AS $$
INSERT INTO posts VALUES (1) RETURNING *;
INSERT INTO posts VALUES (2) RETURNING *;
SELECT max(posts.a), min(posts.a) FROM posts;
$$;
SQL
    @db.call_procedure(:test_procedure_posts, nil, nil).must_equal(:a=>2, :b=>1)
  end if DB.server_version >= 140000

  it "#call_procedure should call a procedure that doesn't return a row" do
    @db.run <<SQL
CREATE OR REPLACE PROCEDURE test_procedure_posts(int, int)
LANGUAGE SQL
AS $$
INSERT INTO posts VALUES ($1) RETURNING *;
INSERT INTO posts VALUES ($1 * 2) RETURNING *;
$$;
SQL
    @db.call_procedure(:test_procedure_posts, 1, nil).must_be_nil
    @db.call_procedure(:test_procedure_posts, 3, nil).must_be_nil
  end unless skip_due_to_pg_bug

  it "#call_procedure should call a procedure that accepts text" do
    @args = 'text'
    @db.run <<SQL
CREATE OR REPLACE PROCEDURE test_procedure_posts(inout t text)
LANGUAGE SQL
AS $$
SELECT 'a' || t;
$$;
SQL
    @db.call_procedure(:test_procedure_posts, 'b').must_equal(:t=>'ab')
  end
end if DB.adapter_scheme == :postgres && DB.server_version >= 110000

describe "Postgres::Dataset#import" do
  before do
    @db = DB
    @db.create_table!(:test){primary_key :x; Integer :y}
    @ds = @db[:test]
  end
  after do
    @db.drop_table?(:test)
  end

  it "#import should a single insert statement" do
    @ds.import([:x, :y], [[1, 2], [3, 4]])
    @ds.all.must_equal [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end

  it "#import should work correctly when returning primary keys" do
    @ds.import([:x, :y], [[1, 2], [3, 4]], :return=>:primary_key).must_equal [1, 3]
    @ds.all.must_equal [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end

  it "#import should work correctly when returning primary keys with :slice option" do
    @ds.import([:x, :y], [[1, 2], [3, 4]], :return=>:primary_key, :slice=>1).must_equal [1, 3]
    @ds.all.must_equal [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end

  it "#import should work correctly with an arbitrary returning value" do
    @ds.returning(:y, :x).import([:x, :y], [[1, 2], [3, 4]]).must_equal [{:y=>2, :x=>1}, {:y=>4, :x=>3}]
    @ds.all.must_equal [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end
end

describe "Postgres::Dataset#import with delayed evaluation as source table" do
  before do
    @db = DB
    @db.create_table!(:test){primary_key :x; Integer :y}
    @ds = @db[Sequel::SQL::DelayedEvaluation.new(lambda{:test})]
  end
  after do
    @db.drop_table?(:test)
  end

  it "#import should work correctly when returning primary keys" do
    @ds.import([:x, :y], [[1, 2], [3, 4]], :return=>:primary_key).must_equal [1, 3]
    @ds.all.must_equal [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end
end

describe "Postgres::Dataset#insert" do
  before do
    @db = DB
    @db.create_table!(:test5){primary_key :xid; Integer :value}
    @ds = @db[:test5]
  end
  after do
    @db.drop_table?(:test5)
  end

  it "should work with static SQL" do
    @ds.with_sql('INSERT INTO test5 (value) VALUES (10)').insert.must_be_nil
    @db['INSERT INTO test5 (value) VALUES (20)'].insert.must_be_nil
    @ds.all.must_equal [{:xid=>1, :value=>10}, {:xid=>2, :value=>20}]
  end

  it "should insert correctly if using a column array and a value array" do
    @ds.insert([:value], [10]).must_equal 1
    @ds.all.must_equal [{:xid=>1, :value=>10}]
  end

  it "should have insert return primary key value" do
    @ds.insert(:value=>10).must_equal 1
  end

  it "should have insert_select insert the record and return the inserted record" do
    h = @ds.insert_select(:value=>10)
    h[:value].must_equal 10
    @ds.first(:xid=>h[:xid])[:value].must_equal 10
  end

  it "should have insert_select respect existing returning clause" do
    h = @ds.returning(Sequel[:value].as(:v), Sequel[:xid].as(:x)).insert_select(:value=>10)
    h[:v].must_equal 10
    @ds.first(:xid=>h[:x])[:value].must_equal 10
  end

  it "should have prepared insert_select respect existing returning clause" do
    h = @ds.returning(Sequel[:value].as(:v), Sequel[:xid].as(:x)).prepare(:insert_select, :insert_select, :value=>10).call
    h[:v].must_equal 10
    @ds.first(:xid=>h[:x])[:value].must_equal 10
  end

  it "should correctly return the inserted record's primary key value" do
    value1 = 10
    id1 = @ds.insert(:value=>value1)
    @ds.first(:xid=>id1)[:value].must_equal value1
    value2 = 20
    id2 = @ds.insert(:value=>value2)
    @ds.first(:xid=>id2)[:value].must_equal value2
  end

  it "should return nil if the table has no primary key" do
    @db.create_table!(:test5){String :name; Integer :value}
    @ds.delete
    @ds.insert(:name=>'a').must_be_nil
  end
end

describe "Postgres::Database schema qualified tables" do
  before do
    @db = DB
    @db << "CREATE SCHEMA schema_test"
    @db.instance_variable_set(:@primary_keys, {})
    @db.instance_variable_set(:@primary_key_sequences, {})
  end
  after do
    @db << "DROP SCHEMA schema_test CASCADE"
  end

  it "should be able to create, drop, select and insert into tables in a given schema" do
    @db.create_table(Sequel[:schema_test][:schema_test]){primary_key :i}
    @db[Sequel[:schema_test][:schema_test]].first.must_be_nil
    @db[Sequel[:schema_test][:schema_test]].insert(:i=>1).must_equal 1
    @db[Sequel[:schema_test][:schema_test]].first.must_equal(:i=>1)
    @db.from(Sequel.lit('schema_test.schema_test')).first.must_equal(:i=>1)
    @db.drop_table(Sequel[:schema_test][:schema_test])
    @db.create_table(Sequel.qualify(:schema_test, :schema_test)){integer :i}
    @db[Sequel[:schema_test][:schema_test]].first.must_be_nil
    @db.from(Sequel.lit('schema_test.schema_test')).first.must_be_nil
    @db.drop_table(Sequel.qualify(:schema_test, :schema_test))
  end

  it "#tables should not include tables in a default non-public schema" do
    @db.create_table(Sequel[:schema_test][:schema_test]){integer :i}
    @db.tables(:schema=>:schema_test).must_include(:schema_test)
    @db.tables.wont_include(:pg_am)
    @db.tables.wont_include(:domain_udt_usage)
  end

  it "#tables should return tables in the schema provided by the :schema argument" do
    @db.create_table(Sequel[:schema_test][:schema_test]){integer :i}
    @db.tables(:schema=>:schema_test).must_equal [:schema_test]
  end

  it "#schema should not include columns from tables in a default non-public schema" do
    @db.create_table(Sequel[:schema_test][:domains]){integer :i}
    sch = @db.schema(Sequel[:schema_test][:domains])
    cs = sch.map{|x| x.first}
    cs.first.must_equal :i
    cs.wont_include(:data_type)
  end

  it "#schema should only include columns from the table in the given :schema argument" do
    @db.create_table!(:domains){integer :d}
    @db.create_table(Sequel[:schema_test][:domains]){integer :i}
    sch = @db.schema(:domains, :schema=>:schema_test)
    cs = sch.map{|x| x.first}
    cs.first.must_equal :i
    cs.wont_include(:d)
    @db.drop_table(:domains)
  end

  it "#schema should not include columns in tables from other domains by default" do
    @db.create_table!(Sequel[:public][:domains]){integer :d}
    @db.create_table(Sequel[:schema_test][:domains]){integer :i}
    begin
      @db.schema(:domains).map{|x| x.first}.must_equal [:d]
      @db.schema(Sequel[:schema_test][:domains]).map{|x| x.first}.must_equal [:i]
    ensure
      @db.drop_table?(Sequel[:public][:domains])
    end
  end

  it "#table_exists? should see if the table is in a given schema" do
    @db.create_table(Sequel[:schema_test][:schema_test]){integer :i}
    @db.table_exists?(Sequel[:schema_test][:schema_test]).must_equal true
  end

  it "should be able to add and drop indexes in a schema" do
    @db.create_table(Sequel[:schema_test][:schema_test]){Integer :i, :index=>true}
    @db.indexes(Sequel[:schema_test][:schema_test]).keys.must_equal [:schema_test_schema_test_i_index]
    @db.drop_index Sequel[:schema_test][:schema_test], :i
    @db.indexes(Sequel[:schema_test][:schema_test]).keys.must_equal []
  end

  it "should be able to get primary keys for tables in a given schema" do
    @db.create_table(Sequel[:schema_test][:schema_test]){primary_key :i}
    @db.primary_key(Sequel[:schema_test][:schema_test]).must_equal 'i'
  end

  it "should be able to get serial sequences for tables in a given schema" do
    @db.create_table(Sequel[:schema_test][:schema_test]){primary_key :i}
    2.times{@db.primary_key_sequence(Sequel[:schema_test][:schema_test]).must_equal '"schema_test"."schema_test_i_seq"'}
  end

  it "should be able to get serial sequences for tables that have spaces in the name in a given schema" do
    @db.create_table(Sequel[:schema_test][:"schema test"]){primary_key :i}
    @db.primary_key_sequence(Sequel[:schema_test][:"schema test"]).must_equal '"schema_test"."schema test_i_seq"'
  end

  it "should be able to get custom sequences for tables in a given schema" do
    @db << "CREATE SEQUENCE schema_test.kseq"
    @db.create_table(Sequel[:schema_test][:schema_test]){integer :j; primary_key :k, :type=>:integer, :default=>Sequel.lit("nextval('schema_test.kseq'::regclass)")}
    @db.primary_key_sequence(Sequel[:schema_test][:schema_test]).must_equal '"schema_test".kseq'
  end

  it "should be able to get custom sequences for tables that have spaces in the name in a given schema" do
    @db << "CREATE SEQUENCE schema_test.\"ks eq\""
    @db.create_table(Sequel[:schema_test][:"schema test"]){integer :j; primary_key :k, :type=>:integer, :default=>Sequel.lit("nextval('schema_test.\"ks eq\"'::regclass)")}
    @db.primary_key_sequence(Sequel[:schema_test][:"schema test"]).must_equal '"schema_test"."ks eq"'
  end

  it "should handle schema introspection cases with tables with same name in multiple schemas" do
    begin
      @db.create_table(Sequel[:schema_test][:schema_test]) do
        primary_key :id
        foreign_key :i, Sequel[:schema_test][:schema_test], :index=>{:name=>:schema_test_sti}
      end
      @db.create_table!(Sequel[:public][:schema_test]) do
        primary_key :id
        foreign_key :j, Sequel[:public][:schema_test], :index=>{:name=>:public_test_sti}
      end

      h = @db.schema(:schema_test)
      h.length.must_equal 2
      h.last.first.must_equal :j

      @db.indexes(:schema_test).must_equal(:public_test_sti=>{:unique=>false, :columns=>[:j], :deferrable=>nil})
      @db.foreign_key_list(:schema_test).must_equal [{:on_update=>:no_action, :columns=>[:j], :deferrable=>false, :key=>[:id], :table=>:schema_test, :on_delete=>:no_action, :name=>:schema_test_j_fkey, :schema=>:public, validated: true, enforced: true}]
    ensure
      @db.drop_table?(Sequel[:public][:schema_test])
    end
  end

  it "should support resetting the primary key sequence" do
    name = Sequel[:schema_test][:schema_test]
    @db.create_table(name){primary_key :id}
    @db[name].insert(:id=>10).must_equal 10
    @db.reset_primary_key_sequence(name).must_equal 11
    @db[name].insert.must_equal 11
    @db[name].select_order_map(:id).must_equal [10, 11]
  end
end

describe "Postgres::Database schema qualified tables and eager graphing" do
  before(:all) do
    @db = DB
    @db.run "DROP SCHEMA s CASCADE" rescue nil
    @db.run "CREATE SCHEMA s"

    @db.create_table(Sequel[:s][:bands]){primary_key :id; String :name}
    @db.create_table(Sequel[:s][:albums]){primary_key :id; String :name; foreign_key :band_id, Sequel[:s][:bands]}
    @db.create_table(Sequel[:s][:tracks]){primary_key :id; String :name; foreign_key :album_id, Sequel[:s][:albums]}
    @db.create_table(Sequel[:s][:members]){primary_key :id; String :name; foreign_key :band_id, Sequel[:s][:bands]}

    @Band = Class.new(Sequel::Model(Sequel[:s][:bands]))
    @Album = Class.new(Sequel::Model(Sequel[:s][:albums]))
    @Track = Class.new(Sequel::Model(Sequel[:s][:tracks]))
    @Member = Class.new(Sequel::Model(Sequel[:s][:members]))
    def @Band.name; :Band; end
    def @Album.name; :Album; end
    def @Track.name; :Track; end
    def @Member.name; :Member; end

    @Band.one_to_many :albums, :class=>@Album, :order=>:name
    @Band.one_to_many :members, :class=>@Member, :order=>:name
    @Album.many_to_one :band, :class=>@Band, :order=>:name
    @Album.one_to_many :tracks, :class=>@Track, :order=>:name
    @Track.many_to_one :album, :class=>@Album, :order=>:name
    @Member.many_to_one :band, :class=>@Band, :order=>:name

    @Member.many_to_many :members, :class=>@Member, :join_table=>Sequel[:s][:bands], :right_key=>:id, :left_key=>:id, :left_primary_key=>:band_id, :right_primary_key=>:band_id, :order=>:name
    @Band.many_to_many :tracks, :class=>@Track, :join_table=>Sequel[:s][:albums], :right_key=>:id, :right_primary_key=>:album_id, :order=>:name

    @b1 = @Band.create(:name=>"BM")
    @b2 = @Band.create(:name=>"J")
    @a1 = @Album.create(:name=>"BM1", :band=>@b1)
    @a2 = @Album.create(:name=>"BM2", :band=>@b1)
    @a3 = @Album.create(:name=>"GH", :band=>@b2)
    @a4 = @Album.create(:name=>"GHL", :band=>@b2)
    @t1 = @Track.create(:name=>"BM1-1", :album=>@a1)
    @t2 = @Track.create(:name=>"BM1-2", :album=>@a1)
    @t3 = @Track.create(:name=>"BM2-1", :album=>@a2)
    @t4 = @Track.create(:name=>"BM2-2", :album=>@a2)
    @m1 = @Member.create(:name=>"NU", :band=>@b1)
    @m2 = @Member.create(:name=>"TS", :band=>@b1)
    @m3 = @Member.create(:name=>"NS", :band=>@b2)
    @m4 = @Member.create(:name=>"JC", :band=>@b2)
  end
  after(:all) do
    @db.run "DROP SCHEMA s CASCADE"
  end

  it "should return all eager graphs correctly" do
    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:albums).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.must_equal [[[@t1, @t2], [@t3, @t4]], [[], []]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph({:albums=>:tracks}, :members).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.must_equal [[[@t1, @t2], [@t3, @t4]], [[], []]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]
  end

  it "should have eager graphs work with previous joins" do
    bands = @Band.order(Sequel[:bands][:name]).select_all(Sequel[:s][:bands]).join(Sequel[:s][:members], :band_id=>:id).from_self(:alias=>:bands0).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.must_equal [[[@t1, @t2], [@t3, @t4]], [[], []]]
  end

  it "should have eager graphs work with joins with the same tables" do
    bands = @Band.order(Sequel[:bands][:name]).select_all(Sequel[:s][:bands]).join(Sequel[:s][:members], :band_id=>:id).eager_graph({:albums=>:tracks}, :members).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.must_equal [[[@t1, @t2], [@t3, @t4]], [[], []]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]
  end

  it "should have eager graphs work with self referential associations" do
    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:tracks=>{:album=>:band}).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]
    bands.map{|x| x.tracks.map{|y| y.album}}.must_equal [[@a1, @a1, @a2, @a2], []]
    bands.map{|x| x.tracks.map{|y| y.album.band}}.must_equal [[@b1, @b1, @b1, @b1], []]

    members = @Member.order(Sequel[:members][:name]).eager_graph(:members).all
    members.must_equal [@m4, @m3, @m1, @m2]
    members.map{|x| x.members}.must_equal [[@m4, @m3], [@m4, @m3], [@m1, @m2], [@m1, @m2]]

    members = @Member.order(Sequel[:members][:name]).eager_graph(:band, :members=>:band).all
    members.must_equal [@m4, @m3, @m1, @m2]
    members.map{|x| x.band}.must_equal [@b2, @b2, @b1, @b1]
    members.map{|x| x.members}.must_equal [[@m4, @m3], [@m4, @m3], [@m1, @m2], [@m1, @m2]]
    members.map{|x| x.members.map{|y| y.band}}.must_equal [[@b2, @b2], [@b2, @b2], [@b1, @b1], [@b1, @b1]]
  end

  it "should have eager graphs work with a from_self dataset" do
    bands = @Band.order(Sequel[:bands][:name]).from_self.eager_graph(:tracks=>{:album=>:band}).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]
    bands.map{|x| x.tracks.map{|y| y.album}}.must_equal [[@a1, @a1, @a2, @a2], []]
    bands.map{|x| x.tracks.map{|y| y.album.band}}.must_equal [[@b1, @b1, @b1, @b1], []]
  end

  it "should have eager graphs work with different types of aliased from tables" do
    bands = @Band.order(Sequel[:tracks][:name]).from(Sequel[:s][:bands].as(:tracks)).eager_graph(:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(Sequel[:tracks][:name]).from(Sequel.expr(Sequel[:s][:bands]).as(:tracks)).eager_graph(:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(Sequel[:tracks][:name]).from(Sequel.expr(Sequel[:s][:bands]).as(Sequel.identifier(:tracks))).eager_graph(:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(Sequel[:tracks][:name]).from(Sequel.expr(Sequel[:s][:bands]).as('tracks')).eager_graph(:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]
  end

  it "should have eager graphs work with join tables with aliases" do
    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:members).join(Sequel[:s][:albums].as(:tracks), :band_id=>Sequel.qualify(Sequel[:s][:bands], :id)).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:members).join(Sequel.as(Sequel[:s][:albums], :tracks), :band_id=>Sequel.qualify(Sequel[:s][:bands], :id)).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:members).join(Sequel.as(Sequel[:s][:albums], 'tracks'), :band_id=>Sequel.qualify(Sequel[:s][:bands], :id)).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:members).join(Sequel.as(Sequel[:s][:albums], Sequel.identifier(:tracks)), :band_id=>Sequel.qualify(Sequel[:s][:bands], :id)).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:members).join(Sequel[:s][:albums], {:band_id=>Sequel.qualify(Sequel[:s][:bands], :id)}, :table_alias=>:tracks).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:members).join(Sequel[:s][:albums], {:band_id=>Sequel.qualify(Sequel[:s][:bands], :id)}, :table_alias=>'tracks').eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(Sequel[:bands][:name]).eager_graph(:members).join(Sequel[:s][:albums], {:band_id=>Sequel.qualify(Sequel[:s][:bands], :id)}, :table_alias=>Sequel.identifier(:tracks)).eager_graph(:albums=>:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.albums}.must_equal [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.must_equal [[@m1, @m2], [@m4, @m3]]
  end

  it "should have eager graphs work with different types of qualified from tables" do
    bands = @Band.order(Sequel[:bands][:name]).from(Sequel.qualify(:s, :bands)).eager_graph(:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(Sequel[:bands][:name]).from(Sequel.identifier(:bands).qualify(:s)).eager_graph(:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(Sequel[:bands][:name]).from(Sequel::SQL::QualifiedIdentifier.new(:s, 'bands')).eager_graph(:tracks).all
    bands.must_equal [@b1, @b2]
    bands.map{|x| x.tracks}.must_equal [[@t1, @t2, @t3, @t4], []]
  end

end

describe "PostgreSQL tsearch2" do
  before(:all) do
    DB.create_table! :test6 do
      text :title
      text :body
      full_text_index [:title, :body]
    end
    @ds = DB[:test6]
  end
  after do
    DB[:test6].delete
  end
  after(:all) do
    DB.drop_table?(:test6)
  end

  it "should search by indexed column" do
    record =  {:title => "oopsla conference", :body => "test"}
    @ds.insert(record)
    @ds.full_text_search(:title, "oopsla").all.must_equal [record]
  end

  it "should join multiple coumns with spaces to search by last words in row" do
    record = {:title => "multiple words", :body => "are easy to search"}
    @ds.insert(record)
    @ds.full_text_search([:title, :body], "words").all.must_equal [record]
  end

  it "should return rows with a NULL in one column if a match in another column" do
    record = {:title => "multiple words", :body =>nil}
    @ds.insert(record)
    @ds.full_text_search([:title, :body], "words").all.must_equal [record]
  end
end

describe "Postgres::Database functions, languages, schemas, and triggers" do
  before do
    @d = DB
  end
  after do
    @d.drop_function('tf', :if_exists=>true, :cascade=>true)
    @d.drop_function('tf', :if_exists=>true, :cascade=>true, :args=>%w'integer integer')
    @d.drop_language(:plpgsql, :if_exists=>true, :cascade=>true) if @d.server_version < 90000
    @d.drop_schema(:sequel, :if_exists=>true, :cascade=>true)
    @d.drop_table?(:test)
  end

  it "#create_function and #drop_function should create and drop functions" do
    proc{@d['SELECT tf()'].all}.must_raise(Sequel::DatabaseError)
    @d.create_function('tf', 'SELECT 1', :returns=>:integer)
    @d['SELECT tf()'].all.must_equal [{:tf=>1}]
    @d.drop_function('tf')
    proc{@d['SELECT tf()'].all}.must_raise(Sequel::DatabaseError)
  end

  it "#create_function and #drop_function should support options" do
    args = ['tf', 'SELECT $1 + $2', {:args=>[[:integer, :a], :integer], :replace=>true, :returns=>:integer, :language=>'SQL', :behavior=>:immutable, :strict=>true, :security_definer=>true, :cost=>2, :parallel=>(:unsafe if @d.server_version >= 90600), :set=>{:search_path => 'public'}}]
    @d.create_function(*args)
    # Make sure replace works
    @d.create_function(*args)
    @d['SELECT tf(1, 2)'].all.must_equal [{:tf=>3}]
    args = ['tf', {:if_exists=>true, :cascade=>true, :args=>[[:integer, :a], :integer]}]
    @d.drop_function(*args)
    # Make sure if exists works
    @d.drop_function(*args)
  end

  it "#create_language and #drop_language should create and drop languages" do
    @d.create_language(:plpgsql, :replace=>true) if @d.server_version < 90000
    proc{@d.create_language(:plpgsql)}.must_raise(Sequel::DatabaseError)
    @d.drop_language(:plpgsql) if @d.server_version < 90000
    proc{@d.drop_language(:plpgsql)}.must_raise(Sequel::DatabaseError) if @d.server_version < 90000
    # Make sure if exists works
    @d.drop_language(:plpgsql, :if_exists=>true, :cascade=>true) if @d.server_version < 90000
  end

  it "#create_schema and #drop_schema should create and drop schemas" do
    @d.create_schema(:sequel)
    @d.create_schema(:sequel, :if_not_exists=>true) if @d.server_version >= 90300
    @d.create_table(Sequel[:sequel][:test]){Integer :a}
    @d.tables(:schema=>:sequel).must_equal [:test]
    @d.tables(:schema=>'sequel').must_equal [:test]
    @d.tables(:schema=>Sequel[:sequel]).must_equal [:test]
    @d.drop_schema(:sequel, :if_exists=>true, :cascade=>true)
  end

  it "#create_trigger and #drop_trigger should create and drop triggers" do
    @d.create_language(:plpgsql) if @d.server_version < 90000
    @d.create_function(:tf, 'BEGIN IF NEW.value IS NULL THEN RAISE EXCEPTION \'Blah\'; END IF; RETURN NEW; END;', :language=>:plpgsql, :returns=>:trigger)
    @d.create_table(:test){String :name; Integer :value}
    @d.create_trigger(:test, :identity, :tf, :each_row=>true)
    @d[:test].insert(:name=>'a', :value=>1)
    @d[:test].filter(:name=>'a').all.must_equal [{:name=>'a', :value=>1}]
    proc{@d[:test].filter(:name=>'a').update(:value=>nil)}.must_raise(Sequel::DatabaseError)
    @d[:test].filter(:name=>'a').all.must_equal [{:name=>'a', :value=>1}]
    @d[:test].filter(:name=>'a').update(:value=>3)
    @d[:test].filter(:name=>'a').all.must_equal [{:name=>'a', :value=>3}]
    @d.drop_trigger(:test, :identity)
    # Make sure if exists works
    @d.drop_trigger(:test, :identity, :if_exists=>true, :cascade=>true)

    if @d.supports_trigger_conditions?
      @d.create_trigger(:test, :identity, :tf, :each_row=>true, :events => :update, :when=> {Sequel[:new][:name] => 'b'})
      @d[:test].filter(:name=>'a').update(:value=>nil)
      @d[:test].filter(:name=>'a').all.must_equal [{:name=>'a', :value=>nil}]
      proc{@d[:test].filter(:name=>'a').update(:name=>'b')}.must_raise(Sequel::DatabaseError)
      @d[:test].filter(:name=>'a').all.must_equal [{:name=>'a', :value=>nil}]

      if @d.server_version >= 140000
        proc{@d[:test].filter(:name=>'a').update(:name=>'b')}.must_raise(Sequel::DatabaseError)
        @d[:test].filter(:name=>'a').update(:name=>'c')
        @d.create_trigger(:test, :identity, :tf, :each_row=>true, :events => :update, :when=> {Sequel[:new][:name] => 'c'}, :replace=>true)
        proc{@d[:test].filter(:name=>'c').update(:name=>'c')}.must_raise(Sequel::DatabaseError)
        @d[:test].filter(:name=>'c').update(:name=>'b')
      end

      @d.drop_trigger(:test, :identity)
    end
  end
end

if DB.adapter_scheme == :postgres
  describe "Postgres::Dataset #use_cursor" do
    before(:all) do
      @db = DB
      @db.create_table!(:test_cursor){Integer :x}
      @ds = @db[:test_cursor]
      @db.transaction{1001.times{|i| @ds.insert(i)}}
    end
    after(:all) do
      @db.drop_table?(:test_cursor)
    end

    it "should return the same results as the non-cursor use" do
      @ds.all.must_equal @ds.use_cursor.all
    end

    it "should not swallow errors if closing cursor raises an error" do
      proc do
        @db.synchronize do |c|
          @ds.use_cursor.each do |r|
            @db.run "CLOSE sequel_cursor"
            raise ArgumentError
          end
        end
      end.must_raise(ArgumentError)
    end

    it "should handle errors raised while closing cursor after successful cursor fetch" do
      proc do
        closed = false
        @db.synchronize do |c|
          @ds.use_cursor(:rows_per_fetch=>2000).each do |r|
            if closed == false
              @db.run "CLOSE sequel_cursor"
              closed = true
            end
          end
        end
      end.must_raise(Sequel::DatabaseError)
    end

    it "should respect the :rows_per_fetch option" do
      i = 0
      @ds = @ds.with_extend{define_method(:execute){|*a, &block| i+=1; super(*a, &block);}}
      @ds.use_cursor.all
      i.must_equal 2

      i = 0
      @ds.use_cursor(:rows_per_fetch=>100).all
      i.must_equal 11

      i = 0
      @ds.use_cursor(:rows_per_fetch=>0).all
      i.must_equal 2

      i = 0
      @ds.use_cursor(:rows_per_fetch=>2000).all
      i.must_equal 1
    end

    it "should respect the :hold=>true option for creating the cursor WITH HOLD and not using a transaction" do
      @ds.use_cursor.each{@db.in_transaction?.must_equal true}
      @ds.use_cursor(:hold=>true).each{@db.in_transaction?.must_equal false}
    end

    it "should support updating individual rows based on a cursor" do
      @db.transaction(:rollback=>:always) do
        @ds.use_cursor(:rows_per_fetch=>1).each do |row|
          @ds.where_current_of.update(:x=>Sequel.*(row[:x], 10))
        end
        @ds.select_order_map(:x).must_equal((0..1000).map{|x| x * 10})
      end
      @ds.select_order_map(:x).must_equal((0..1000).to_a)
    end

    it "should respect the :cursor_name option" do
      one_rows = []
      two_rows = []
      @ds.order(:x).use_cursor(:cursor_name => 'cursor_one').each do |one|
        one_rows << one
        if one[:x] % 1000 == 500 
          two_rows = []
          @ds.order(:x).use_cursor(:cursor_name => 'cursor_two').each do |two|
            two_rows << two
          end
        end
      end
      one_rows.must_equal two_rows
    end

    it "should handle returning inside block" do
      ds = @ds.with_extend do
        def check_return
          use_cursor.each{|r| return}
        end
      end
      ds.check_return
      ds.all.must_equal ds.use_cursor.all
    end
  end

  describe "Database#add_named_conversion_proc" do
    before(:all) do
      @db = DB
      @old_cp = @db.conversion_procs[1013]
      @db.conversion_procs.delete(1013)
      @db.add_named_conversion_proc(:oidvector, &:reverse)
    end
    after(:all) do
      @db.conversion_procs.delete(30)
      @db.conversion_procs[1013] = @old_cp
      @db.drop_table?(:foo)
      @db.drop_enum(:foo_enum) rescue nil
    end

    it "should work for scalar types" do
      @db.create_table!(:foo){oidvector :bar}
      @db[:foo].insert(Sequel.cast('21', :oidvector))
      @db[:foo].get(:bar).must_equal '12'
    end

    it "should work for array types" do
      @db.create_table!(:foo){column :bar, 'oidvector[]'}
      @db[:foo].insert(Sequel.pg_array(['21'], :oidvector))
      @db[:foo].get(:bar).must_equal ['12']
    end

    it "should work with for enums" do
      @db.drop_enum(:foo_enum) rescue nil
      @db.create_enum(:foo_enum, %w(foo bar))
      @db.add_named_conversion_proc(:foo_enum, &:reverse)
      @db.create_table!(:foo){foo_enum :bar}
      @db[:foo].insert(:bar => 'foo')
      @db[:foo].get(:bar).must_equal 'foo'.reverse
    end

    it "should raise error for unsupported type" do
      proc{@db.add_named_conversion_proc(:nonexistant_type, &:reverse)}.must_raise Sequel::Error
    end
  end
end

if uses_pg_or_jdbc && DB.server_version >= 90000
  describe "Postgres::Database#copy_into" do
    before(:all) do
      @db = DB
      @db.create_table!(:test_copy){Integer :x; Integer :y}
      @ds = @db[:test_copy].order(:x, :y)
    end
    before do
      @db[:test_copy].delete
    end
    after(:all) do
      @db.drop_table?(:test_copy)
    end

    it "should work with a :data option containing data in PostgreSQL text format" do
      @db.copy_into(:test_copy, :data=>"1\t2\n3\t4\n")
      @ds.select_map([:x, :y]).must_equal [[1, 2], [3, 4]]
    end

    it "should work with :format=>:csv option and :data option containing data in CSV format" do
      @db.copy_into(:test_copy, :format=>:csv, :data=>"1,2\n3,4\n")
      @ds.select_map([:x, :y]).must_equal [[1, 2], [3, 4]]
    end

    it "should respect given :options" do
      @db.copy_into(:test_copy, :options=>"FORMAT csv, HEADER TRUE", :data=>"x,y\n1,2\n3,4\n")
      @ds.select_map([:x, :y]).must_equal [[1, 2], [3, 4]]
    end

    it "should respect given :options options when :format is used" do
      @db.copy_into(:test_copy, :options=>"QUOTE '''', DELIMITER '|'", :format=>:csv, :data=>"'1'|'2'\n'3'|'4'\n")
      @ds.select_map([:x, :y]).must_equal [[1, 2], [3, 4]]
    end

    it "should accept :columns option to online copy the given columns" do
      @db.copy_into(:test_copy, :data=>"1\t2\n3\t4\n", :columns=>[:y, :x])
      @ds.select_map([:x, :y]).must_equal [[2, 1], [4, 3]]
    end

    it "should accept a block and use returned values for the copy in data stream" do
      buf = ["1\t2\n", "3\t4\n"]
      @db.copy_into(:test_copy){buf.shift}
      @ds.select_map([:x, :y]).must_equal [[1, 2], [3, 4]]
    end

    it "should work correctly with a block and :format=>:csv" do
      buf = ["1,2\n", "3,4\n"]
      @db.copy_into(:test_copy, :format=>:csv){buf.shift}
      @ds.select_map([:x, :y]).must_equal [[1, 2], [3, 4]]
    end

    it "should accept an enumerable as the :data option" do
      @db.copy_into(:test_copy, :data=>["1\t2\n", "3\t4\n"])
      @ds.select_map([:x, :y]).must_equal [[1, 2], [3, 4]]
    end

    it "should have an exception, cause a rollback of copied data and still have a usable connection" do
      2.times do
        sent = false
        proc{@db.copy_into(:test_copy){raise ArgumentError if sent; sent = true; "1\t2\n"}}.must_raise(ArgumentError)
        @ds.select_map([:x, :y]).must_equal []
      end
    end

    it "should handle database errors with a rollback of copied data and still have a usable connection" do
      2.times do
        proc{@db.copy_into(:test_copy, :data=>["1\t2\n", "3\ta\n"])}.must_raise(Sequel::DatabaseError)
        @ds.select_map([:x, :y]).must_equal []
      end
    end

    it "should raise an Error if both :data and a block are provided" do
      proc{@db.copy_into(:test_copy, :data=>["1\t2\n", "3\t4\n"]){}}.must_raise(Sequel::Error)
    end

    it "should raise an Error if neither :data or a block are provided" do
      proc{@db.copy_into(:test_copy)}.must_raise(Sequel::Error)
    end
  end

  describe "Postgres::Database#copy_into using UTF-8 encoding" do
    before(:all) do
      @db = DB
      @db.create_table!(:test_copy){String :t}
      @ds = @db[:test_copy].order(:t)
    end
    before do
      @db[:test_copy].delete
    end
    after(:all) do
      @db.drop_table?(:test_copy)
    end

    it "should work with UTF-8 characters using the :data option" do
      @db.copy_into(:test_copy, :data=>(["\u00E4\n"]*2))
      @ds.select_map([:t]).map{|a| a.map{|s| s.force_encoding('UTF-8')}}.must_equal([["\u00E4"]] * 2)
    end

    it "should work with UTF-8 characters using a block" do
      buf = (["\u00E4\n"]*2)
      @db.copy_into(:test_copy){buf.shift}
      @ds.select_map([:t]).map{|a| a.map{|s| s.force_encoding('UTF-8')}}.must_equal([["\u00E4"]] * 2)
    end
  end

  describe "Postgres::Database#copy_table" do
    before(:all) do
      @db = DB
      @db.create_table!(:test_copy){Integer :x; Integer :y}
      ds = @db[:test_copy]
      ds.insert(1, 2)
      ds.insert(3, 4)
    end
    after(:all) do
      @db.drop_table?(:test_copy)
    end

    it "without a block or options should return a text version of the table as a single string" do
      @db.copy_table(:test_copy).must_equal "1\t2\n3\t4\n"
    end

    it "without a block and with :format=>:csv should return a csv version of the table as a single string" do
      @db.copy_table(:test_copy, :format=>:csv).must_equal "1,2\n3,4\n"
    end

    it "should treat string as SQL code" do
      @db.copy_table('COPY "test_copy" TO STDOUT').must_equal "1\t2\n3\t4\n"
    end

    it "should respect given :options options" do
      @db.copy_table(:test_copy, :options=>"FORMAT csv, HEADER TRUE").must_equal "x,y\n1,2\n3,4\n"
    end

    it "should respect given :options options when :format is used" do
      @db.copy_table(:test_copy, :format=>:csv, :options=>"QUOTE '''', FORCE_QUOTE *").must_equal "'1','2'\n'3','4'\n"
    end

    it "should accept dataset as first argument" do
      @db.copy_table(@db[:test_copy].cross_join(Sequel[:test_copy].as(:tc)).order(Sequel[:test_copy][:x], Sequel[:test_copy][:y], Sequel[:tc][:x], Sequel[:tc][:y])).must_equal "1\t2\t1\t2\n1\t2\t3\t4\n3\t4\t1\t2\n3\t4\t3\t4\n"
    end

    it "with a block and no options should yield each row as a string in text format" do
      buf = []
      @db.copy_table(:test_copy){|b| buf << b}
      buf.must_equal ["1\t2\n", "3\t4\n"]
    end

    it "with a block and :format=>:csv should yield each row as a string in csv format" do
      buf = []
      @db.copy_table(:test_copy, :format=>:csv){|b| buf << b}
      buf.must_equal ["1,2\n", "3,4\n"]
    end

    it "should work fine when using a block that is terminated early with a following copy_table" do
      buf = []
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; break}}.must_raise(Sequel::DatabaseDisconnectError)
      buf.must_equal ["1,2\n"]
      buf.clear
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; raise ArgumentError}}.must_raise(Sequel::DatabaseDisconnectError)
      buf.must_equal ["1,2\n"]
      buf.clear
      @db.copy_table(:test_copy){|b| buf << b}
      buf.must_equal ["1\t2\n", "3\t4\n"]
    end

    it "should work fine when using a block that is terminated early with a following regular query" do
      buf = []
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; break}}.must_raise(Sequel::DatabaseDisconnectError)
      buf.must_equal ["1,2\n"]
      buf.clear
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; raise ArgumentError}}.must_raise(Sequel::DatabaseDisconnectError)
      buf.must_equal ["1,2\n"]
      @db[:test_copy].select_order_map(:x).must_equal [1, 3]
    end

    it "should not swallow error raised by block" do
      begin
        @db.copy_table(:test_copy){|b| raise ArgumentError, "foo"}
      rescue => e
      end

      e.must_be_kind_of Sequel::DatabaseDisconnectError
      e.wrapped_exception.must_be_kind_of ArgumentError
      e.message.must_include "foo"
    end

    it "should handle errors raised during row processing" do
      proc{@db.copy_table(@db[:test_copy].select(Sequel[1]/(Sequel[:x] - 3)))}.must_raise Sequel::DatabaseError
      @db.get(1).must_equal 1
    end

    it "should disconnect if the result status after the copy is not expected" do
      proc do
        @db.synchronize do |c|
          def c.get_last_result; end
          @db.copy_table(:test_copy)
        end
      end.must_raise Sequel::DatabaseDisconnectError
    end if uses_pg
  end
end

if uses_pg && DB.server_version >= 90000
  describe "Postgres::Database LISTEN/NOTIFY" do
    before(:all) do
      @db = DB
    end

    it "should support listen and notify" do
      # Spec assumes only one connection currently in the pool (otherwise notify_pid will not be deterministic)
      @db.disconnect

      notify_pid = @db.synchronize{|conn| conn.backend_pid}

      called = false
      @db.listen('foo', :after_listen=>proc{@db.notify('foo')}) do |ev, pid, payload|
        ev.must_equal 'foo'
        pid.must_equal notify_pid
        ['', nil].must_include(payload)
        called = true
      end.must_equal 'foo'
      called.must_equal true

      # Check weird identifier names
      called = false
      @db.listen('FOO bar', :after_listen=>proc{@db.notify('FOO bar')}) do |ev, pid, payload|
        ev.must_equal 'FOO bar'
        pid.must_equal notify_pid
        ['', nil].must_include(payload)
        called = true
      end.must_equal 'FOO bar'
      called.must_equal true

      # Check identifier symbols
      called = false
      @db.listen(:foo, :after_listen=>proc{@db.notify(:foo)}) do |ev, pid, payload|
        ev.must_equal 'foo'
        pid.must_equal notify_pid
        ['', nil].must_include(payload)
        called = true
      end.must_equal 'foo'
      called.must_equal true

      called = false
      @db.listen('foo', :after_listen=>proc{@db.notify('foo', :payload=>'bar')}) do |ev, pid, payload|
        ev.must_equal 'foo'
        pid.must_equal notify_pid
        payload.must_equal 'bar'
        called = true
      end.must_equal 'foo'
      called.must_equal true

      @db.listen('foo', :after_listen=>proc{@db.notify('foo')}).must_equal 'foo'

      called = false
      called2 = false
      i = 0
      @db.listen(['foo', 'bar'], :after_listen=>proc{@db.notify('foo', :payload=>'bar'); @db.notify('bar', :payload=>'foo')}, :loop=>proc{i+=1}) do |ev, pid, payload|
        if !called
          ev.must_equal 'foo'
          pid.must_equal notify_pid
          payload.must_equal 'bar'
          called = true
        else
          ev.must_equal 'bar'
          pid.must_equal notify_pid
          payload.must_equal 'foo'
          called2 = true
          break
        end
      end.must_be_nil
      called.must_equal true
      called2.must_equal true
      i.must_equal 1

      proc{@db.listen('foo', :loop=>true)}.must_raise Sequel::Error
    end

    it "should accept a :timeout option in listen" do
      @db.listen('foo2', :timeout=>0.001).must_be_nil
      called = false
      @db.listen('foo2', :timeout=>0.001){|ev, pid, payload| called = true}.must_be_nil
      called.must_equal false
      i = 0
      @db.listen('foo2', :timeout=>0.001, :loop=>proc{i+=1; throw :stop if i > 3}){|ev, pid, payload| called = true}.must_be_nil
      i.must_equal 4

      called = false
      i = 0
      @db.listen('foo2', :timeout=>proc{i+=1; 0.001}){|ev, pid, payload| called = true}.must_be_nil
      called.must_equal false
      i.must_equal 1

      i = 0
      t = 0
      @db.listen('foo2', :timeout=>proc{t+=1; 0.001}, :loop=>proc{i+=1; throw :stop if i > 3}){|ev, pid, payload| called = true}.must_be_nil
      called.must_equal false
      t.must_equal 4

      t = 0
      @db.listen('foo2', :timeout=>proc{t+=1; throw :stop if t == 4; 0.001}, :loop=>true){|ev, pid, payload| called = true}.must_be_nil
      called.must_equal false
      t.must_equal 4

    end unless RUBY_PLATFORM =~ /mingw/ # Ruby freezes on this spec on this platform/version
  end
end

describe 'PostgreSQL special float handling' do
  before do
    @db = DB
    @db.create_table!(:test5){Float :value}
    @ds = @db[:test5]
  end
  after do
    @db.drop_table?(:test5)
  end

  it 'inserts NaN' do
    nan = 0.0/0.0
    @ds.insert(:value=>nan)
    @ds.all[0][:value].nan?.must_equal true
  end

  it 'inserts +Infinity' do
    inf = 1.0/0.0
    @ds.insert(:value=>inf)
    @ds.all[0][:value].infinite?.must_be :>,  0
  end

  it 'inserts -Infinity' do
    inf = -1.0/0.0
    @ds.insert(:value=>inf)
    @ds.all[0][:value].infinite?.must_be :<,  0
  end
end if DB.adapter_scheme == :postgres

describe 'PostgreSQL array handling' do
  before(:all) do
    @db = DB
    @ds = @db[:items]
    @tp = lambda{@db.schema(:items).map{|a| a.last[:type]}}
  end
  after do
    @db.drop_table?(:items)
  end

  it 'insert and retrieve integer and float arrays of various sizes' do
    @db.create_table!(:items) do
      column :i2, 'int2[]'
      column :i4, 'int4[]'
      column :i8, 'int8[]'
      column :r, 'real[]'
      column :dp, 'double precision[]'
    end
    @tp.call.must_equal [:smallint_array, :integer_array, :bigint_array, :real_array, :float_array]
    @ds.insert(Sequel.pg_array([1], :int2), Sequel.pg_array([nil, 2], :int4), Sequel.pg_array([3, nil], :int8), Sequel.pg_array([4, nil, 4.5], :real), Sequel.pg_array([5, nil, 5.5], "double precision"))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:i2=>[1], :i4=>[nil, 2], :i8=>[3, nil], :r=>[4.0, nil, 4.5], :dp=>[5.0, nil, 5.5]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    @ds.delete
    @ds.insert(Sequel.pg_array([[1], [2]], :int2), Sequel.pg_array([[nil, 2], [3, 4]], :int4), Sequel.pg_array([[3, nil], [nil, nil]], :int8), Sequel.pg_array([[4, nil], [nil, 4.5]], :real), Sequel.pg_array([[5, nil], [nil, 5.5]], "double precision"))

    rs = @ds.all
    rs.must_equal [{:i2=>[[1], [2]], :i4=>[[nil, 2], [3, 4]], :i8=>[[3, nil], [nil, nil]], :r=>[[4, nil], [nil, 4.5]], :dp=>[[5, nil], [nil, 5.5]]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'insert and retrieve decimal arrays' do
    @db.create_table!(:items) do
      column :n, 'numeric[]'
    end
    @tp.call.must_equal [:decimal_array]
    @ds.insert(Sequel.pg_array([BigDecimal('1.000000000000000000001'), nil, BigDecimal('1')], :numeric))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:n=>[BigDecimal('1.000000000000000000001'), nil, BigDecimal('1')]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    @ds.delete
    @ds.insert(Sequel.pg_array([[BigDecimal('1.0000000000000000000000000000001'), nil], [nil, BigDecimal('1')]], :numeric))
    rs = @ds.all
    rs.must_equal [{:n=>[[BigDecimal('1.0000000000000000000000000000001'), nil], [nil, BigDecimal('1')]]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'insert and retrieve string arrays' do
    @db.create_table!(:items) do
      column :c, 'char(4)[]'
      column :vc, 'varchar[]'
      column :t, 'text[]'
    end
    @tp.call.must_equal [:character_array, :varchar_array, :string_array]
    @ds.insert(Sequel.pg_array(['a', nil, 'NULL', 'b"\'c'], 'char(4)'), Sequel.pg_array(['a', nil, 'NULL', 'b"\'c', '', ''], :varchar), Sequel.pg_array(['a', nil, 'NULL', 'b"\'c'], :text))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:c=>['a   ', nil, 'NULL', 'b"\'c'], :vc=>['a', nil, 'NULL', 'b"\'c', '', ''], :t=>['a', nil, 'NULL', 'b"\'c']}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    @ds.delete
    @ds.insert(Sequel.pg_array([[['a'], [nil]], [['NULL'], ['b"\'c']]], 'char(4)'), Sequel.pg_array([[['a[],\\[\\]\\,\\""NULL",'], ['']], [['NULL'], ['b"\'c']]], :varchar), Sequel.pg_array([[['a'], [nil]], [['NULL'], ['b"\'c']]], :text))
    rs = @ds.all
    rs.must_equal [{:c=>[[['a   '], [nil]], [['NULL'], ['b"\'c']]], :vc=>[[['a[],\\[\\]\\,\\""NULL",'], ['']], [['NULL'], ['b"\'c']]], :t=>[[['a'], [nil]], [['NULL'], ['b"\'c']]]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'insert and retrieve arrays of other types' do
    @db.create_table!(:items) do
      column :b, 'bool[]'
      column :d, 'date[]'
      column :t, 'time[]'
      column :ts, 'timestamp[]'
      column :tstz, 'timestamptz[]'
    end
    @tp.call.must_equal [:boolean_array, :date_array, :time_array, :datetime_array, :datetime_timezone_array]

    d = Date.today
    t = Sequel::SQLTime.create(10, 20, 30)
    ts = Time.local(2011, 1, 2, 3, 4, 5)

    @ds.insert(Sequel.pg_array([true, false], :bool), Sequel.pg_array([d, nil], :date), Sequel.pg_array([t, nil], :time), Sequel.pg_array([ts, nil], :timestamp), Sequel.pg_array([ts, nil], :timestamptz))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:b=>[true, false], :d=>[d, nil], :t=>[t, nil], :ts=>[ts, nil], :tstz=>[ts, nil]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    @db.create_table!(:items) do
      column :ba, 'bytea[]'
      column :tz, 'timetz[]'
      column :o, 'oid[]'
    end
    @tp.call.must_equal [:blob_array, :time_timezone_array, :oid_array]
    @ds.insert(Sequel.pg_array([Sequel.blob("a\0"), nil], :bytea), Sequel.pg_array([t, nil], :timetz), Sequel.pg_array([1, 2, 3], :oid))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:ba=>[Sequel.blob("a\0"), nil], :tz=>[t, nil], :o=>[1, 2, 3]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    @db.create_table!(:items) do
      column :x, 'xml[]'
      column :m, 'money[]'
      column :b, 'bit[]'
      column :vb, 'bit varying[]'
      column :u, 'uuid[]'
      column :xi, 'xid[]'
      column :c, 'cid[]'
      column :n, 'name[]'
      column :o, 'oidvector[]'
    end
    @tp.call.must_equal [:xml_array, :money_array, :bit_array, :varbit_array, :uuid_array, :xid_array, :cid_array, :name_array, :oidvector_array]
    
    begin
      @db.transaction(:rollback=>:always) do
        @ds.insert(:x=>Sequel.pg_array(['<a></a>'], :xml))
      end
    rescue Sequel::DatabaseError
    else
      xml_insert_value = Sequel.pg_array(['<a></a>'], :xml)
      xml_expected_value = ['<a></a>']
    end

    @ds.insert(xml_insert_value,
               Sequel.pg_array(['1'], :money),
               Sequel.pg_array(['1'], :bit),
               Sequel.pg_array(['10'], :varbit),
               Sequel.pg_array(['c0f24910-39e7-11e4-916c-0800200c9a66'], :uuid),
               Sequel.pg_array(['12'], :xid),
               Sequel.pg_array(['12'], :cid),
               Sequel.pg_array(['N'], :name),
               Sequel.pg_array(['1 2'], :oidvector))
    @ds.count.must_equal 1
    rs = @ds.all
    r = rs.first
    m = r.delete(:m)
    m.class.must_equal(Sequel::Postgres::PGArray)
    m.to_a.must_be_kind_of(Array)
    m.first.must_be_kind_of(String)
    r.must_be(:==, :x=>xml_expected_value, :b=>['1'], :vb=>['10'], :u=>['c0f24910-39e7-11e4-916c-0800200c9a66'], :xi=>['12'], :c=>['12'], :n=>['N'], :o=>['1 2'])
    x = r.delete(:x)
    r.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    r.values.each{|v| v.to_a.must_be_kind_of(Array)}
    r[:m] = m
    r[:x] = x
    @ds.delete
    @ds.insert(r)
    @ds.all.must_equal rs
  end

  it 'insert and retrieve empty arrays' do
    @db.create_table!(:items) do
      column :n, 'integer[]'
    end
    @ds.insert(:n=>Sequel.pg_array([], :integer))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:n=>[]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'convert ruby array :default values' do
    @db.create_table!(:items) do
      column :n, 'integer[]', :default=>[]
    end
    @ds.insert
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:n=>[]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'insert and retrieve custom array types' do
    point= Class.new do
      attr_reader :array
      def initialize(array)
        @array = array
      end
      def sql_literal_append(ds, sql)
        sql << "'(#{array.join(',')})'"
      end
      def ==(other)
        if other.is_a?(self.class)
          array == other.array
        else
          super
        end
      end
    end
    @db.register_array_type(:point){|s| point.new(s[1...-1].split(',').map{|i| i.to_i})}
    @db.create_table!(:items) do
      column :b, 'point[]'
    end
    @tp.call.must_equal [:point_array]
    pv = point.new([1, 2])
    @ds.insert(Sequel.pg_array([pv], :point))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.must_equal [{:b=>[pv]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'retrieve arrays with explicit bounds' do
    @db.create_table!(:items) do
      column :n, 'integer[]'
    end
    @ds.insert(:n=>"[0:1]={2,3}")
    rs = @ds.all
    rs.must_equal [{:n=>[2,3]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    @ds.delete
    @ds.insert(:n=>"[0:1][0:0]={{2},{3}}")
    rs = @ds.all
    rs.must_equal [{:n=>[[2], [3]]}]
    rs.first.values.each{|v| v.class.must_equal(Sequel::Postgres::PGArray)}
    rs.first.values.each{|v| v.to_a.must_be_kind_of(Array)}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'use arrays in bound variables' do
    @db.create_table!(:items) do
      column :i, 'int4[]'
    end
    @ds.call(:insert, {:i=>[1,2]}, :i=>:$i)
    @ds.get(:i).must_equal [1, 2]
    @ds.filter(:i=>:$i).call(:first, :i=>[1,2]).must_equal(:i=>[1,2])
    @ds.filter(:i=>:$i).call(:first, :i=>[1,3]).must_be_nil

    # NULL values
    @ds.delete
    @ds.call(:insert, {:i=>[nil,nil]}, :i=>:$i)
    @ds.first.must_equal(:i=>[nil, nil])

    @db.create_table!(:items) do
      column :i, 'text[]'
    end
    a = ["\"\\\\\"{}\n\t\r \v\b123afP", 'NULL', nil, '']
    @ds.call(:insert, {:i=>Sequel.pg_array(a)}, :i=>:$i)
    @ds.get(:i).must_equal a
    @ds.filter(:i=>:$i).call(:first, :i=>a).must_equal(:i=>a)
    @ds.filter(:i=>:$i).call(:first, :i=>['', nil, nil, 'a']).must_be_nil

    @db.create_table!(:items) do
      column :i, 'date[]'
    end
    a = [Date.today]
    @ds.call(:insert, {:i=>Sequel.pg_array(a, 'date')}, :i=>:$i)
    @ds.get(:i).must_equal a
    @ds.filter(:i=>:$i).call(:first, :i=>a).must_equal(:i=>a)
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.pg_array([Date.today-1], 'date')).must_be_nil

    @db.create_table!(:items) do
      column :i, 'timestamp[]'
    end
    a = [Time.local(2011, 1, 2, 3, 4, 5)]
    @ds.call(:insert, {:i=>Sequel.pg_array(a, 'timestamp')}, :i=>:$i)
    @ds.get(:i).must_equal a
    @ds.filter(:i=>:$i).call(:first, :i=>a).must_equal(:i=>a)
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.pg_array([a.first-1], 'timestamp')).must_be_nil

    @db.create_table!(:items) do
      column :i, 'boolean[]'
    end
    a = [true, false]
    @ds.call(:insert, {:i=>Sequel.pg_array(a, 'boolean')}, :i=>:$i)
    @ds.get(:i).must_equal a
    @ds.filter(:i=>:$i).call(:first, :i=>a).must_equal(:i=>a)
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.pg_array([false, true], 'boolean')).must_be_nil

    @db.create_table!(:items) do
      column :i, 'bytea[]'
    end
    a = [Sequel.blob("a\0'\"")]
    @ds.call(:insert, {:i=>Sequel.pg_array(a, 'bytea')}, :i=>:$i)
    @ds.get(:i).must_equal a
    @ds.filter(:i=>:$i).call(:first, :i=>a).must_equal(:i=>a)
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.pg_array([Sequel.blob("b\0")], 'bytea')).must_be_nil
  end if uses_pg_or_jdbc

  it 'with models' do
    @db.create_table!(:items) do
      primary_key :id
      column :i, 'integer[]'
      column :f, 'double precision[]'
      column :d, 'numeric[]'
      column :t, 'text[]'
    end
    c = Class.new(Sequel::Model(@db[:items]))
    h = {:i=>[1,2, nil], :f=>[[1, 2.5], [3, 4.5]], :d=>[1, BigDecimal('1.000000000000000000001')], :t=>[%w'a b c', ['NULL', nil, '1']]}
    o = c.create(h)
    o.i.must_equal [1, 2, nil]
    o.f.must_equal [[1, 2.5], [3, 4.5]]
    o.d.must_equal [BigDecimal('1'), BigDecimal('1.000000000000000000001')]
    o.t.must_equal [%w'a b c', ['NULL', nil, '1']]
    c.where(:i=>o.i, :f=>o.f, :d=>o.d, :t=>o.t).all.must_equal [o]
    o2 = c.new(h)
    c.where(:i=>o2.i, :f=>o2.f, :d=>o2.d, :t=>o2.t).all.must_equal [o]

    @db.create_table!(:items) do
      primary_key :id
      column :i, 'int2[]'
      column :f, 'real[]'
      column :d, 'numeric(30,28)[]'
      column :t, 'varchar[]'
    end
    c = Class.new(Sequel::Model(@db[:items]))
    o = c.create(:i=>[1,2, nil], :f=>[[1, 2.5], [3, 4.5]], :d=>[1, BigDecimal('1.000000000000000000001')], :t=>[%w'a b c', ['NULL', nil, '1']])
    o.i.must_equal [1, 2, nil]
    o.f.must_equal [[1, 2.5], [3, 4.5]]
    o.d.must_equal [BigDecimal('1'), BigDecimal('1.000000000000000000001')]
    o.t.must_equal [%w'a b c', ['NULL', nil, '1']]
    c.where(:i=>o.i, :f=>o.f, :d=>o.d, :t=>o.t).all.must_equal [o]
    o2 = c.new(h)
    c.where(:i=>o2.i, :f=>o2.f, :d=>o2.d, :t=>o2.t).all.must_equal [o]
  end

  it 'with empty array default values and defaults_setter plugin' do
    @db.create_table!(:items) do
      column :n, 'integer[]', :default=>[]
    end
    c = Class.new(Sequel::Model(@db[:items]))
    c.plugin :defaults_setter, :cache=>true
    o = c.new
    o.n.class.must_equal(Sequel::Postgres::PGArray)
    o.n.to_a.must_be_same_as(o.n.to_a)
    o.n << 1
    o.save.n.must_equal [1]
  end

  it 'operations/functions with pg_array_ops' do
    Sequel.extension :pg_array_ops
    @db.create_table!(:items){column :i, 'integer[]'; column :i2, 'integer[]'; column :i3, 'integer[]'; column :i4, 'integer[]'; column :i5, 'integer[]'}
    @ds.insert(Sequel.pg_array([1, 2, 3]), Sequel.pg_array([2, 1]), Sequel.pg_array([4, 4]), Sequel.pg_array([[5, 5], [4, 3]]), Sequel.pg_array([1, nil, 5]))

    @ds.get(Sequel.pg_array(:i) > :i3).must_equal false
    @ds.get(Sequel.pg_array(:i3) > :i).must_equal true

    @ds.get(Sequel.pg_array(:i) >= :i3).must_equal false
    @ds.get(Sequel.pg_array(:i) >= :i).must_equal true

    @ds.get(Sequel.pg_array(:i3) < :i).must_equal false
    @ds.get(Sequel.pg_array(:i) < :i3).must_equal true

    @ds.get(Sequel.pg_array(:i3) <= :i).must_equal false
    @ds.get(Sequel.pg_array(:i) <= :i).must_equal true

    @ds.get(Sequel.expr(5=>Sequel.pg_array(:i).any)).must_equal false
    @ds.get(Sequel.expr(1=>Sequel.pg_array(:i).any)).must_equal true

    @ds.get(Sequel.expr(1=>Sequel.pg_array(:i3).all)).must_equal false
    @ds.get(Sequel.expr(4=>Sequel.pg_array(:i3).all)).must_equal true

    @ds.get(Sequel.expr(1=>Sequel.pg_array(:i)[1..1].any)).must_equal true
    @ds.get(Sequel.expr(2=>Sequel.pg_array(:i)[1..1].any)).must_equal false

    @ds.get(Sequel.pg_array(:i2)[1]).must_equal 2
    @ds.get(Sequel.pg_array(:i2)[1]).must_equal 2
    @ds.get(Sequel.pg_array(:i2)[2]).must_equal 1

    @ds.get(Sequel.pg_array(:i4)[2][1]).must_equal 4
    @ds.get(Sequel.pg_array(:i4)[2][2]).must_equal 3

    @ds.get(Sequel.pg_array(:i).contains(:i2)).must_equal true
    @ds.get(Sequel.pg_array(:i).contains(:i3)).must_equal false

    @ds.get(Sequel.pg_array(:i2).contained_by(:i)).must_equal true
    @ds.get(Sequel.pg_array(:i).contained_by(:i2)).must_equal false

    @ds.get(Sequel.pg_array(:i).overlaps(:i2)).must_equal true
    @ds.get(Sequel.pg_array(:i2).overlaps(:i3)).must_equal false

    @ds.get(Sequel.pg_array(:i).dims).must_equal '[1:3]'
    @ds.get(Sequel.pg_array(:i).length).must_equal 3
    @ds.get(Sequel.pg_array(:i).lower).must_equal 1

    @ds.select(Sequel.pg_array(:i).unnest).from_self.count.must_equal 3
    if @db.server_version >= 90000
      @ds.get(Sequel.pg_array(:i5).join).must_equal '15'
      @ds.get(Sequel.pg_array(:i5).join(':')).must_equal '1:5'
    end
    if @db.server_version >= 90100
      @ds.get(Sequel.pg_array(:i5).join(':', '*')).must_equal '1:*:5'
    end
    if @db.server_version >= 90300
      @ds.get(Sequel.pg_array(:i5).remove(1).length).must_equal 2
      @ds.get(Sequel.pg_array(:i5).replace(1, 4).contains([1])).must_equal false
      @ds.get(Sequel.pg_array(:i5).replace(1, 4).contains([4])).must_equal true
    end
    if @db.server_version >= 90400
      @ds.get(Sequel.pg_array(:i).cardinality).must_equal 3
      @ds.get(Sequel.pg_array(:i4).cardinality).must_equal 4
      @ds.get(Sequel.pg_array(:i5).cardinality).must_equal 3

      @ds.from{Sequel.pg_array([1,2,3]).op.unnest([4,5,6], [7,8]).as(:t1, [:a, :b, :c])}.select_order_map([:a, :b, :c]).must_equal [[1, 4, 7], [2, 5, 8], [3, 6, nil]]
    end

    @ds.get(Sequel.pg_array(:i).push(4)).must_equal [1, 2, 3, 4]
    @ds.get(Sequel.pg_array(:i).unshift(4)).must_equal [4, 1, 2, 3]
    @ds.get(Sequel.pg_array(:i).concat(:i2)).must_equal [1, 2, 3, 2, 1]

    if @db.type_supported?(:hstore)
      Sequel.extension :pg_hstore_ops
      @db.get(Sequel.pg_array(['a', 'b']).op.hstore['a']).must_equal 'b'
      @db.get(Sequel.pg_array(['a', 'b']).op.hstore(['c', 'd'])['a']).must_equal 'c'
    end
  end
end

describe 'PostgreSQL hstore handling' do
  before(:all) do
    @db = DB
    @ds = @db[:items]
    @h = {'a'=>'b', 'c'=>nil, 'd'=>'NULL', 'e'=>'\\\\" \\\' ,=>'}
  end
  after do
    @db.drop_table?(:items)
  end

  it 'insert and retrieve hstore values' do
    @db.create_table!(:items) do
      column :h, :hstore
    end
    @ds.insert(Sequel.hstore(@h))
    @ds.count.must_equal 1
    rs = @ds.all
    v = rs.first[:h]
    v.must_equal @h
    v.class.must_equal(Sequel::Postgres::HStore)
    v.to_hash.must_be_kind_of(Hash)
    v.to_hash.must_equal @h
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'insert and retrieve hstore[] values' do
    @db.create_table!(:items) do
      column :h, 'hstore[]'
    end
    @ds.insert(Sequel.pg_array([Sequel.hstore(@h)], :hstore))
    @ds.count.must_equal 1
    rs = @ds.all
    v = rs.first[:h].first
    v.class.must_equal(Sequel::Postgres::HStore)
    v.to_hash.must_be_kind_of(Hash)
    v.to_hash.must_equal @h
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'use hstore in bound variables' do
    @db.create_table!(:items) do
      column :i, :hstore
    end
    @ds.call(:insert, {:i=>Sequel.hstore(@h)}, {:i=>:$i})
    @ds.get(:i).must_equal @h
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.hstore(@h)).must_equal(:i=>@h)
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.hstore({})).must_be_nil

    @ds.delete
    @ds.call(:insert, {:i=>Sequel.hstore('a'=>nil)}, {:i=>:$i})
    @ds.get(:i).must_equal Sequel.hstore('a'=>nil)

    @ds.delete
    @ds.call(:insert, {:i=>@h}, {:i=>:$i})
    @ds.get(:i).must_equal @h
    @ds.filter(:i=>:$i).call(:first, :i=>@h).must_equal(:i=>@h)
    @ds.filter(:i=>:$i).call(:first, :i=>{}).must_be_nil

    @db.create_table!(:items) do
      column :i, 'hstore[]'
    end
    @ds.call(:insert, {:i=>Sequel.pg_array([Sequel.hstore(@h)], :hstore)}, {:i=>:$i})
    @ds.get(:i).must_equal [@h]
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.pg_array([Sequel.hstore(@h)], :hstore)).must_equal(:i=>[@h])
    @ds.filter(:i=>:$i).call(:first, :i=>Sequel.pg_array([Sequel.hstore({})], :hstore)).must_be_nil

    @ds.delete
    @ds.call(:insert, {:i=>Sequel.pg_array([Sequel.hstore('a'=>nil)], :hstore)}, {:i=>:$i})
    @ds.get(:i).must_equal [Sequel.hstore('a'=>nil)]
  end if uses_pg_or_jdbc

  it 'with models and associations' do
    @db.create_table!(:items) do
      primary_key :id
      column :h, :hstore
    end
    c = Class.new(Sequel::Model(@db[:items])) do
      def self.name
        'Item'
      end
      unrestrict_primary_key
      def item_id
        h['item_id'].to_i if h
      end
      def left_item_id
        h['left_item_id'].to_i if h
      end
    end
    Sequel.extension :pg_hstore_ops
    c.plugin :many_through_many

    h = {'item_id'=>"2", 'left_item_id'=>"1"}
    o2 = c.create(:id=>2)
    o = c.create(:id=>1, :h=>h)
    o.h.must_equal h

    c.many_to_one :item, :class=>c, :key_column=>Sequel.cast(Sequel.hstore(:h)['item_id'], Integer)
    c.one_to_many :items, :class=>c, :key=>Sequel.cast(Sequel.hstore(:h)['item_id'], Integer), :key_method=>:item_id
    c.many_to_many :related_items, :class=>c, :join_table=>Sequel[:items].as(:i), :left_key=>Sequel.cast(Sequel.hstore(:h)['left_item_id'], Integer), :right_key=>Sequel.cast(Sequel.hstore(:h)['item_id'], Integer)

    c.many_to_one :other_item, :class=>c, :key=>:id, :primary_key_method=>:item_id, :primary_key=>Sequel.cast(Sequel.hstore(:h)['item_id'], Integer), :reciprocal=>:other_items
    c.one_to_many :other_items, :class=>c, :primary_key=>:item_id, :key=>:id, :primary_key_column=>Sequel.cast(Sequel.hstore(:h)['item_id'], Integer), :reciprocal=>:other_item
    c.many_to_many :other_related_items, :class=>c, :join_table=>Sequel[:items].as(:i), :left_key=>:id, :right_key=>:id,
      :left_primary_key_column=>Sequel.cast(Sequel.hstore(:h)['left_item_id'], Integer),
      :left_primary_key=>:left_item_id,
      :right_primary_key=>Sequel.cast(Sequel.hstore(:h)['left_item_id'], Integer),
      :right_primary_key_method=>:left_item_id

    c.many_through_many :mtm_items, [
        [:items, Sequel.cast(Sequel.hstore(:h)['item_id'], Integer), Sequel.cast(Sequel.hstore(:h)['left_item_id'], Integer)],
        [:items, Sequel.cast(Sequel.hstore(:h)['left_item_id'], Integer), Sequel.cast(Sequel.hstore(:h)['left_item_id'], Integer)]
      ],
      :class=>c,
      :left_primary_key_column=>Sequel.cast(Sequel.hstore(:h)['item_id'], Integer),
      :left_primary_key=>:item_id,
      :right_primary_key=>Sequel.cast(Sequel.hstore(:h)['left_item_id'], Integer),
      :right_primary_key_method=>:left_item_id

    # Lazily Loading
    o.item.must_equal o2
    o2.items.must_equal [o]
    o.related_items.must_equal [o2]
    o2.other_item.must_equal o
    o.other_items.must_equal [o2]
    o.other_related_items.must_equal [o]
    o.mtm_items.must_equal [o]

    # Eager Loading via eager
    os = c.eager(:item, :related_items, :other_items, :other_related_items, :mtm_items).where(:id=>1).all.first
    os.item.must_equal o2
    os.related_items.must_equal [o2]
    os.other_items.must_equal [o2]
    os.other_related_items.must_equal [o]
    os.mtm_items.must_equal [o]
    os = c.eager(:items, :other_item).where(:id=>2).all.first
    os.items.must_equal [o]
    os.other_item.must_equal o

    # Eager Loading via eager_graph
    c.eager_graph(:item).where(Sequel[:items][:id]=>1).all.first.item.must_equal o2
    c.eager_graph(:items).where(Sequel[:items][:id]=>2).all.first.items.must_equal [o]
    c.eager_graph(:related_items).where(Sequel[:items][:id]=>1).all.first.related_items.must_equal [o2]
    c.eager_graph(:other_item).where(Sequel[:items][:id]=>2).all.first.other_item.must_equal o
    c.eager_graph(:other_items).where(Sequel[:items][:id]=>1).all.first.other_items.must_equal [o2]
    c.eager_graph(:other_related_items).where(Sequel[:items][:id]=>1).all.first.other_related_items.must_equal [o]
    c.eager_graph(:mtm_items).where(Sequel[:items][:id]=>1).all.first.mtm_items.must_equal [o]

    # Filter By Associations - Model Instances
    c.filter(:item=>o2).all.must_equal [o]
    c.filter(:items=>o).all.must_equal [o2]
    c.filter(:related_items=>o2).all.must_equal [o]
    c.filter(:other_item=>o).all.must_equal [o2]
    c.filter(:other_items=>o2).all.must_equal [o]
    c.filter(:other_related_items=>o).all.must_equal [o]
    c.filter(:mtm_items=>o).all.must_equal [o]
   
    # Filter By Associations - Model Datasets
    c.filter(:item=>c.filter(:id=>o2.id)).all.must_equal [o]
    c.filter(:items=>c.filter(:id=>o.id)).all.must_equal [o2]
    c.filter(:related_items=>c.filter(:id=>o2.id)).all.must_equal [o]
    c.filter(:other_item=>c.filter(:id=>o.id)).all.must_equal [o2]
    c.filter(:other_items=>c.filter(:id=>o2.id)).all.must_equal [o]
    c.filter(:other_related_items=>c.filter(:id=>o.id)).all.must_equal [o]
    c.filter(:mtm_items=>c.filter(:id=>o.id)).all.must_equal [o]
  end

  it 'with empty hstore default values and defaults_setter plugin' do
    @db.create_table!(:items) do
      hstore :h, :default=>Sequel.hstore({})
    end
    c = Class.new(Sequel::Model(@db[:items]))
    c.plugin :defaults_setter, :cache=>true
    o = c.new
    o.h.class.must_equal(Sequel::Postgres::HStore)
    o.h.to_hash.must_be_same_as(o.h.to_hash)
    o.h['a'] = 'b'
    o.save.h.must_equal('a'=>'b')
  end

  it 'operations/functions with pg_hstore_ops' do
    Sequel.extension :pg_hstore_ops, :pg_array_ops
    @db.create_table!(:items){hstore :h1; hstore :h2; hstore :h3; String :t}
    @ds.insert(Sequel.hstore('a'=>'b', 'c'=>nil), Sequel.hstore('a'=>'b'), Sequel.hstore('d'=>'e'))
    h1 = Sequel.hstore(:h1)
    h2 = Sequel.hstore(:h2)
    h3 = Sequel.hstore(:h3)
    
    @ds.get(h1['a']).must_equal 'b'
    @ds.get(h1['d']).must_be_nil

    @ds.get(h2.concat(h3).keys.length).must_equal 2
    @ds.get(h1.concat(h3).keys.length).must_equal 3
    @ds.get(h2.merge(h3).keys.length).must_equal 2
    @ds.get(h1.merge(h3).keys.length).must_equal 3

    @ds.get(h1.contain_all(%w'a c')).must_equal true
    @ds.get(h1.contain_all(%w'a d')).must_equal false

    @ds.get(h1.contain_any(%w'a d')).must_equal true
    @ds.get(h1.contain_any(%w'e d')).must_equal false

    @ds.get(h1.contains(h2)).must_equal true
    @ds.get(h1.contains(h3)).must_equal false

    @ds.get(h2.contained_by(h1)).must_equal true
    @ds.get(h2.contained_by(h3)).must_equal false

    @ds.get(h1.defined('a')).must_equal true
    @ds.get(h1.defined('c')).must_equal false
    @ds.get(h1.defined('d')).must_equal false

    @ds.get(h1.delete('a')['c']).must_be_nil
    @ds.get(h1.delete(%w'a d')['c']).must_be_nil
    @ds.get(h1.delete(h2)['c']).must_be_nil

    @ds.from(Sequel.hstore('a'=>'b', 'c'=>nil).op.each).order(:key).all.must_equal [{:key=>'a', :value=>'b'}, {:key=>'c', :value=>nil}]

    @ds.get(h1.has_key?('c')).must_equal true
    @ds.get(h1.include?('c')).must_equal true
    @ds.get(h1.key?('c')).must_equal true
    @ds.get(h1.member?('c')).must_equal true
    @ds.get(h1.exist?('c')).must_equal true
    @ds.get(h1.has_key?('d')).must_equal false
    @ds.get(h1.include?('d')).must_equal false
    @ds.get(h1.key?('d')).must_equal false
    @ds.get(h1.member?('d')).must_equal false
    @ds.get(h1.exist?('d')).must_equal false

    @ds.get(h1.hstore.hstore.hstore.keys.length).must_equal 2
    @ds.get(h1.keys.length).must_equal 2
    @ds.get(h2.keys.length).must_equal 1
    @ds.get(h1.akeys.length).must_equal 2
    @ds.get(h2.akeys.length).must_equal 1

    @ds.from(Sequel.hstore('t'=>'s').op.populate(Sequel::SQL::Cast.new(nil, :items))).select_map(:t).must_equal ['s']
    @ds.from(Sequel[:items].as(:i)).select(Sequel.hstore('t'=>'s').op.record_set(:i).as(:r)).from_self(:alias=>:s).select(Sequel.lit('(r).*')).from_self.select_map(:t).must_equal ['s']

    @ds.from(Sequel.hstore('t'=>'s', 'a'=>'b').op.skeys.as(:s)).select_order_map(:s).must_equal %w'a t'
    @ds.from((Sequel.hstore('t'=>'s', 'a'=>'b').op - 'a').skeys.as(:s)).select_order_map(:s).must_equal %w't'

    @ds.get(h1.slice(%w'a c').keys.length).must_equal 2
    @ds.get(h1.slice(%w'd c').keys.length).must_equal 1
    @ds.get(h1.slice(%w'd e').keys.length).must_be_nil

    @ds.from(Sequel.hstore('t'=>'s', 'a'=>'b').op.svals.as(:s)).select_order_map(:s).must_equal %w'b s'

    @ds.get(h1.to_array.length).must_equal 4
    @ds.get(h2.to_array.length).must_equal 2

    @ds.get(h1.to_matrix.length).must_equal 2
    @ds.get(h2.to_matrix.length).must_equal 1

    @ds.get(h1.values.length).must_equal 2
    @ds.get(h2.values.length).must_equal 1
    @ds.get(h1.avals.length).must_equal 2
    @ds.get(h2.avals.length).must_equal 1

    if DB.server_version >= 140000
      @ds.update(h1['a'] => '2', h1['b'] => '3', h1['c'] => '4')
      @ds.get(:h1).must_equal("a"=>"2", "b"=>"3", "c"=>"4")
    end
  end
end if DB.type_supported?(:hstore)

describe 'PostgreSQL' do
  before(:all) do
    @db = DB
    @ds = @db[:items]
    @a = [1, 2, {'a'=>'b'}, 3.0]
    @h = {'a'=>'b', '1'=>[3, 4, 5]}
  end
  after do
    @db.wrap_json_primitives = nil
    @db.typecast_json_strings = nil
    @db.drop_table?(:items)
  end

  json_types = [:json]
  json_types << :jsonb if DB.server_version >= 90400
  json_types.each do |json_type|
    json_array_type = "#{json_type}[]"
    pg_json = Sequel.method(:"pg_#{json_type}")
    pg_json_wrap = Sequel.method(:"pg_#{json_type}_wrap")
    hash_class = json_type == :jsonb ? Sequel::Postgres::JSONBHash : Sequel::Postgres::JSONHash
    array_class = json_type == :jsonb ? Sequel::Postgres::JSONBArray : Sequel::Postgres::JSONArray
    str_class = json_type == :jsonb ? Sequel::Postgres::JSONBString : Sequel::Postgres::JSONString
    object_class = json_type == :jsonb ? Sequel::Postgres::JSONBObject : Sequel::Postgres::JSONObject
    Sequel.extension :pg_json_ops
    jo = pg_json.call('a'=>1, 'b'=>{'c'=>2, 'd'=>{'e'=>3}}).op
    ja = pg_json.call([2, 3, %w'a b']).op

    it "insert and retrieve #{json_type} values" do
      @db.create_table!(:items){column :j, json_type}
      @ds.insert(pg_json.call(@h))
      @ds.count.must_equal 1
      rs = @ds.all
      v = rs.first[:j]
      v.class.must_equal(hash_class)
      v.to_hash.must_be_kind_of(Hash)
      v.must_equal @h
      v.to_hash.must_equal @h
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs

      @ds.delete
      @ds.insert(pg_json.call(@a))
      @ds.count.must_equal 1
      rs = @ds.all
      v = rs.first[:j]
      v.class.must_equal(array_class)
      v.to_a.must_be_kind_of(Array)
      v.must_equal @a
      v.to_a.must_equal @a
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs
    end

    it "insert and retrieve #{json_type} primitive values" do
      @db.create_table!(:items){column :j, json_type}
      ['str', 1, 2.5, nil, true, false].each do |rv|
        @ds.delete
        @ds.insert(pg_json_wrap.call(rv))
        @ds.count.must_equal 1
        rs = @ds.all
        v = rs.first[:j]
        v.class.must_equal(rv.class)
        if rv.nil?
          v.must_be_nil
        else
          v.must_equal rv
        end
      end

      @db.wrap_json_primitives = true
      ['str', 1, 2.5, nil, true, false].each do |rv|
        @ds.delete
        @ds.insert(pg_json_wrap.call(rv))
        @ds.count.must_equal 1
        rs = @ds.all
        v = rs.first[:j]
        v.class.ancestors.must_include(object_class)
        v.__getobj__.must_be_kind_of(rv.class)
        if rv.nil?
          v.must_be_nil
          v.__getobj__.must_be_nil
        else
          v.must_equal rv
          v.__getobj__.must_equal rv
        end
        @ds.delete
        @ds.insert(rs.first)
        @ds.all[0][:j].must_equal rs[0][:j]
      end
    end

    it "insert and retrieve #{json_type}[] values" do
      @db.create_table!(:items){column :j, json_array_type}
      j = Sequel.pg_array([pg_json.call('a'=>1), pg_json.call(['b', 2])])
      @ds.insert(j)
      @ds.count.must_equal 1
      rs = @ds.all
      v = rs.first[:j]
      v.class.must_equal(Sequel::Postgres::PGArray)
      v.to_a.must_be_kind_of(Array)
      v.must_equal j
      v.to_a.must_equal j
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs
    end

    it "insert and retrieve #{json_type}[] values with json primitives" do
      @db.create_table!(:items){column :j, json_array_type}
      raw = ['str', 1, 2.5, nil, true, false]
      j = Sequel.pg_array(raw.map(&pg_json_wrap), json_type)
      @ds.insert(j)
      @ds.count.must_equal 1
      rs = @ds.all
      v = rs.first[:j]
      v.class.must_equal(Sequel::Postgres::PGArray)
      v.to_a.must_be_kind_of(Array)
      v.map(&:class).must_equal raw.map(&:class)
      v.must_equal raw
      v.to_a.must_equal raw

      @db.wrap_json_primitives = true
      j = Sequel.pg_array(raw.map(&pg_json_wrap), json_type)
      @ds.insert(j)
      rs = @ds.all
      v = rs.first[:j]
      v.class.must_equal(Sequel::Postgres::PGArray)
      v.to_a.must_be_kind_of(Array)
      v.map(&:class).each{|c| c.ancestors.must_include(object_class)}
      [v, v.to_a].each do |v0|
        v0.zip(raw) do |v1, r1|
          if r1.nil?
            v1.must_be_nil
            v1.__getobj__.must_be_nil
          else
            v1.must_equal r1
            v1.__getobj__.must_equal r1
          end
        end
      end
      @ds.delete
      @ds.insert(rs.first)
      @ds.all[0][:j].zip(rs[0][:j]) do |v1, r1|
        if v1.__getobj__.nil?
          v1.must_be_nil
          v1.__getobj__.must_be_nil
        else
          v1.must_equal r1
          v1.must_equal r1.__getobj__
          v1.__getobj__.must_equal r1
          v1.__getobj__.must_equal r1.__getobj__
        end
      end
    end

    it "models with #{json_type} columns" do
      @db.create_table!(:items) do
        primary_key :id
        column :h, json_type
      end
      c = Class.new(Sequel::Model(@db[:items]))
      c.create(:h=>@h).h.must_equal @h
      c.create(:h=>@a).h.must_equal @a
      c.create(:h=>pg_json.call(@h)).h.must_equal @h
      c.create(:h=>pg_json.call(@a)).h.must_equal @a
    end

    it "models with #{json_type} primitives" do
      @db.create_table!(:items) do
        primary_key :id
        column :h, json_type
      end
      c = Class.new(Sequel::Model(@db[:items]))

      ['str', 1, 2.5, nil, true, false].each do |v|
        @db.wrap_json_primitives = nil
        cv = c[c.insert(:h=>pg_json_wrap.call(v))]
        cv.h.class.ancestors.wont_include(object_class)
        if v.nil?
          cv.h.must_be_nil
        else
          cv.h.must_equal v
        end

        @db.wrap_json_primitives = true
        cv.refresh
        cv.h.class.ancestors.must_include(object_class)
        cv.save
        cv.refresh
        cv.h.class

        if v.nil?
          cv.h.must_be_nil
        else
          cv.h.must_equal v
        end

        c.new(:h=>cv.h).h.class.ancestors.must_include(object_class)
      end

      v = c.new(:h=>'{}').h
      v.class.must_equal hash_class
      v.must_equal({})
      @db.typecast_json_strings = true
      v = c.new(:h=>'{}').h
      v.class.must_equal str_class
      v.must_equal '{}'

      c.new(:h=>'str').h.class.ancestors.must_include(object_class)
      c.new(:h=>'str').h.must_equal 'str'
      c.new(:h=>1).h.class.ancestors.must_include(object_class)
      c.new(:h=>1).h.must_equal 1
      c.new(:h=>2.5).h.class.ancestors.must_include(object_class)
      c.new(:h=>2.5).h.must_equal 2.5
      c.new(:h=>true).h.class.ancestors.must_include(object_class)
      c.new(:h=>true).h.must_equal true
      c.new(:h=>false).h.class.ancestors.must_include(object_class)
      c.new(:h=>false).h.must_equal false

      c.new(:h=>nil).h.class.ancestors.wont_include(object_class)
      c.new(:h=>nil).h.must_be_nil
    end

    it "with empty #{json_type} default values and defaults_setter plugin" do
      @db.create_table!(:items) do
        column :h, json_type, :default=>hash_class.new({})
        column :a, json_type, :default=>array_class.new([])
      end
      c = Class.new(Sequel::Model(@db[:items]))
      c.plugin :defaults_setter, :cache=>true
      o = c.new
      o.h.class.must_equal(hash_class)
      o.a.class.must_equal(array_class)
      o.h.to_hash.must_be_same_as(o.h.to_hash)
      o.a.to_a.must_be_same_as(o.a.to_a)
      o.h['a'] = 'b'
      o.a << 1
      o.save
      o.h.must_equal('a'=>'b')
      o.a.must_equal([1])
    end

    it "use #{json_type} in bound variables" do
      @db.create_table!(:items){column :i, json_type}
      @ds.call(:insert, {:i=>pg_json.call(@h)}, {:i=>:$i})
      @ds.get(:i).must_equal @h

      @ds.delete
      @ds.call(:insert, {:i=>pg_json.call('a'=>nil)}, {:i=>:$i})
      @ds.get(:i).must_equal pg_json.call('a'=>nil)

      @db.create_table!(:items){column :i, json_array_type}
      j = Sequel.pg_array([pg_json.call('a'=>1), pg_json.call(['b', 2])], json_type)
      @ds.call(:insert, {:i=>j}, {:i=>:$i})
      @ds.get(:i).must_equal j
    end if uses_pg_or_jdbc

    it "use #{json_type} primitives in bound variables" do
      @db.create_table!(:items){column :i, json_type}
      @db.wrap_json_primitives = true
      raw = ['str', 1, 2.5, nil, true, false]
      raw.each do |v|
        @ds.delete
        @ds.call(:insert, {:i=>@db.get(pg_json_wrap.call(v))}, {:i=>:$i})
        rv = @ds.get(:i)
        rv.class.ancestors.must_include(object_class)
        if v.nil?
          rv.must_be_nil
        else
          rv.must_equal v
        end
      end

      @db.create_table!(:items){column :i, json_array_type}
      j = Sequel.pg_array(raw.map(&pg_json_wrap), json_type)
      @ds.call(:insert, {:i=>j}, {:i=>:$i})
      @ds.all[0][:i].zip(raw) do |v1, r1|
        if v1.__getobj__.nil?
          v1.must_be_nil
          v1.__getobj__.must_be_nil
        else
          v1.must_equal r1
          v1.__getobj__.must_equal r1
        end
      end
    end if uses_pg_or_jdbc

    it "9.3 #{json_type} operations/functions with pg_json_ops" do
      @db.get(jo['a']).must_equal 1
      @db.get(jo['b']['c']).must_equal 2
      @db.get(jo[%w'b c']).must_equal 2
      @db.get(jo['b'].get_text(%w'd e')).must_equal "3"
      @db.get(jo[%w'b d'].get_text('e')).must_equal "3"
      @db.get(ja[1]).must_equal 3
      @db.get(ja[%w'2 1']).must_equal 'b'

      @db.get(jo.extract('a')).must_equal 1
      @db.get(jo.extract('b').extract('c')).must_equal 2
      @db.get(jo.extract('b', 'c')).must_equal 2
      @db.get(jo.extract('b', 'd', 'e')).must_equal 3
      @db.get(jo.extract_text('b', 'd')).delete(' ').must_equal '{"e":3}'
      @db.get(jo.extract_text('b', 'd', 'e')).must_equal '3'

      @db.get(ja.array_length).must_equal 3
      @db.from(ja.array_elements.as(:v)).select_map(:v).must_equal [2, 3, %w'a b']

      @db.from(jo.keys.as(:k)).select_order_map(:k).must_equal %w'a b'
      @db.from(jo.each).select_order_map(:key).must_equal %w'a b'
      @db.from(jo.each).order(:key).select_map(:value).must_equal [1, {'c'=>2, 'd'=>{'e'=>3}}]
      @db.from(jo.each_text).select_order_map(:key).must_equal %w'a b'
      @db.from(jo.each_text).order(:key).where(:key=>'b').get(:value).delete(' ').must_match(/\{"d":\{"e":3\},"c":2\}|\{"c":2,"d":\{"e":3\}\}/)

      Sequel.extension :pg_row_ops
      @db.create_table!(:items) do
        Integer :a
        String :b
      end
      j = Sequel.pg_json('a'=>1, 'b'=>'c').op
      @db.get(j.populate(Sequel.cast(nil, :items)).pg_row[:a]).must_equal 1
      @db.get(j.populate(Sequel.cast(nil, :items)).pg_row[:b]).must_equal 'c'
      j = Sequel.pg_json([{'a'=>1, 'b'=>'c'}, {'a'=>2, 'b'=>'d'}]).op
      @db.from(j.populate_set(Sequel.cast(nil, :items))).select_order_map(:a).must_equal [1, 2]
      @db.from(j.populate_set(Sequel.cast(nil, :items))).select_order_map(:b).must_equal %w'c d'
    end if DB.server_version >= 90300

    it "9.4 #{json_type} operations/functions with pg_json_ops" do
      @db.get(jo.typeof).must_equal 'object'
      @db.get(ja.typeof).must_equal 'array'
      @db.from(ja.array_elements_text.as(:v)).select_map(:v).map{|s| s.delete(' ')}.must_equal ['2', '3', '["a","b"]']
      @db.from(jo.to_record.as(:v, [Sequel.lit('a integer'), Sequel.lit('b text')])).select_map(:a).must_equal [1]
      @db.from(pg_json.call([{'a'=>1, 'b'=>1}]).op.to_recordset.as(:v, [[:a, Integer], [:b, Integer]])).select_map(:a).must_equal [1]

      if json_type == :jsonb
        @db.get(jo.has_key?('a')).must_equal true
        @db.get(jo.has_key?('c')).must_equal false
        @db.get(pg_json.call(['2', '3', %w'a b']).op.include?('2')).must_equal true
        @db.get(pg_json.call(['2', '3', %w'a b']).op.include?('4')).must_equal false

        @db.get(jo.contain_all(['a', 'b'])).must_equal true
        @db.get(jo.contain_all(['a', 'c'])).must_equal false
        @db.get(jo.contain_all(['d', 'c'])).must_equal false
        @db.get(jo.contain_any(['a', 'b'])).must_equal true
        @db.get(jo.contain_any(['a', 'c'])).must_equal true
        @db.get(jo.contain_any(['d', 'c'])).must_equal false

        @db.get(jo.contains(jo)).must_equal true
        @db.get(jo.contained_by(jo)).must_equal true
        @db.get(jo.contains('a'=>1)).must_equal true
        @db.get(jo.contained_by('a'=>1)).must_equal false
        @db.get(pg_json.call('a'=>1).op.contains(jo)).must_equal false
        @db.get(pg_json.call('a'=>1).op.contained_by(jo)).must_equal true

        @db.get(ja.contains(ja)).must_equal true
        @db.get(ja.contained_by(ja)).must_equal true
        @db.get(ja.contains([2,3])).must_equal true
        @db.get(ja.contained_by([2,3])).must_equal false
        @db.get(pg_json.call([2,3]).op.contains(ja)).must_equal false
        @db.get(pg_json.call([2,3]).op.contained_by(ja)).must_equal true
      end
    end if DB.server_version >= 90400 

    it '9.5 jsonb operations/functions with pg_json_ops' do
      @db.get(pg_json.call([nil, 2]).op.strip_nulls[1]).must_equal 2
      @db.get(pg_json.call([nil, 2]).op.pretty).must_equal "[\n    null,\n    2\n]"
      @db.from((jo - 'b').keys.as(:k)).select_order_map(:k).must_equal %w'a'
      @db.from(jo.delete_path(['b','c'])['b'].keys.as(:k)).select_order_map(:k).must_equal %w'd'
      @db.from(jo.concat('c'=>'d').keys.as(:k)).select_order_map(:k).must_equal %w'a b c'
      @db.get(jo.set(%w'a', 'f'=>'g')['a']['f']).must_equal 'g'
    end if DB.server_version >= 90500 && json_type == :jsonb

    it '9.6 jsonb operations/functions with pg_json_ops' do
      @db.get(pg_json.call([3]).op.insert(['0'], {'a'=>2})[0]['a']).must_equal 2
      @db.get(pg_json.call([3]).op.insert(['0'], {'a'=>2}, false)[0]['a']).must_equal 2
      @db.get(pg_json.call([3]).op.insert(['0'], {'a'=>2}, true)[0]).must_equal 3
      @db.get(pg_json.call([3]).op.insert(['0'], {'a'=>2}, true)[1]['a']).must_equal 2
    end if DB.server_version >= 90600  && json_type == :jsonb

    it '12 jsonb operations/functions with pg_json_ops' do
      @db.get(jo.path_exists('$.b.d.e')).must_equal true
      @db.get(jo.path_exists('$.b.d.f')).must_equal false

      @db.get(jo.path_exists!('$.b.d.e')).must_equal true
      @db.get(jo.path_exists!('$.b.d.f')).must_equal false
      @db.get(jo.path_exists!('$.b.d.e ? (@ > $x)', '{"x":2}')).must_equal true
      @db.get(jo.path_exists!('$.b.d.e ? (@ > $x)', '{"x":4}')).must_equal false
      @db.get(jo.path_exists!('$.b.d.e ? (@ > $x)', x: 2)).must_equal true
      @db.get(jo.path_exists!('$.b.d.e ? (@ > $x)', x: 4)).must_equal false
      @db.get(jo.path_exists!('$.b.d.e ? (@ > $x)', {x: 2}, true)).must_equal true
      @db.get(jo.path_exists!('$.b.d.e ? (@ > $x)', {x: 4}, false)).must_equal false

      @db.get(jo.path_match('$.b.d.e')).must_be_nil
      @db.get(jo.path_match('$.b.d.f')).must_be_nil
      @db.get(pg_json.call('b'=>{'d'=>{'e'=>true}}).op.path_match('$.b.d.e')).must_equal true
      @db.get(pg_json.call('b'=>{'d'=>{'e'=>false}}).op.path_match('$.b.d.e')).must_equal false

      proc{@db.get(jo.path_match!('$.b.d.e'))}.must_raise(Sequel::DatabaseError)
      proc{@db.get(jo.path_match!('$.b.d.f'))}.must_raise(Sequel::DatabaseError)
      @db.get(jo.path_match!('$.b.d.e', {}, true)).must_be_nil
      @db.get(jo.path_match!('$.b.d.f', {}, true)).must_be_nil
      @db.get(pg_json.call('b'=>{'d'=>{'e'=>true}}).op.path_match!('$.b.d.e')).must_equal true
      @db.get(pg_json.call('b'=>{'d'=>{'e'=>false}}).op.path_match!('$.b.d.e')).must_equal false
      @db.get(jo.path_match!('$.b.d.e > $x', '{"x":2}')).must_equal true
      @db.get(jo.path_match!('$.b.d.e > $x', '{"x":4}')).must_equal false
      @db.get(jo.path_match!('$.b.d.e > $x', x: 2)).must_equal true
      @db.get(jo.path_match!('$.b.d.e > $x', x: 4)).must_equal false
      @db.get(jo.path_match!('$.b.d.e > $x', {x: 2}, false)).must_equal true
      @db.get(jo.path_match!('$.b.d.e > $x', {x: 4}, true)).must_equal false

      @db.get(jo.path_query_first('$.b.d.e')).must_equal 3
      @db.get(jo.path_query_first('$.b.d.f')).must_be_nil
      @db.get(jo.path_query_first('$.b.d.e ? (@ > $x)', '{"x":2}')).must_equal 3
      @db.get(jo.path_query_first('$.b.d.e ? (@ > $x)', '{"x":4}')).must_be_nil
      @db.get(jo.path_query_first('$.b.d.e ? (@ > $x)', x: 2)).must_equal 3
      @db.get(jo.path_query_first('$.b.d.e ? (@ > $x)', x: 4)).must_be_nil
      @db.get(jo.path_query_first('$.b.d.e ? (@ > $x)', {x: 2}, true)).must_equal 3
      @db.get(jo.path_query_first('$.b.d.e ? (@ > $x)', {x: 4}, false)).must_be_nil

      @db.get(jo.path_query_array('$.b.d.e')).must_equal [3]
      @db.get(jo.path_query_array('$.b.d.f')).must_equal []
      @db.get(jo.path_query_array('$.b.d.e ? (@ > $x)', '{"x":2}')).must_equal [3]
      @db.get(jo.path_query_array('$.b.d.e ? (@ > $x)', '{"x":4}')).must_equal []
      @db.get(jo.path_query_array('$.b.d.e ? (@ > $x)', x: 2)).must_equal [3]
      @db.get(jo.path_query_array('$.b.d.e ? (@ > $x)', x: 4)).must_equal []
      @db.get(jo.path_query_array('$.b.d.e ? (@ > $x)', {x: 2}, true)).must_equal [3]
      @db.get(jo.path_query_array('$.b.d.e ? (@ > $x)', {x: 4}, false)).must_equal []

      @db.from(jo.path_query('$.b.d.e').as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query('$.b.d.f').as(:a, [:b])).get(:b).must_be_nil
      @db.from(jo.path_query('$.b.d.e ? (@ > $x)', '{"x":2}').as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query('$.b.d.e ? (@ > $x)', '{"x":4}').as(:a, [:b])).get(:b).must_be_nil
      @db.from(jo.path_query('$.b.d.e ? (@ > $x)', x: 2).as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query('$.b.d.e ? (@ > $x)', x: 4).as(:a, [:b])).get(:b).must_be_nil
      @db.from(jo.path_query('$.b.d.e ? (@ > $x)', {x: 2}, true).as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query('$.b.d.e ? (@ > $x)', {x: 4}, false).as(:a, [:b])).get(:b).must_be_nil
    end if DB.server_version >= 120000  && json_type == :jsonb

    it '13 jsonb operations/functions with pg_json_ops' do
      @db.get(jo.set_lax(%w'a', 'f'=>'g')['a']['f']).must_equal 'g'

      @db.get(jo.path_exists_tz!('$.b.d.e')).must_equal true
      @db.get(jo.path_exists_tz!('$.b.d.f')).must_equal false
      @db.get(jo.path_exists_tz!('$.b.d.e ? (@ > $x)', '{"x":2}')).must_equal true
      @db.get(jo.path_exists_tz!('$.b.d.e ? (@ > $x)', '{"x":4}')).must_equal false
      @db.get(jo.path_exists_tz!('$.b.d.e ? (@ > $x)', x: 2)).must_equal true
      @db.get(jo.path_exists_tz!('$.b.d.e ? (@ > $x)', x: 4)).must_equal false
      @db.get(jo.path_exists_tz!('$.b.d.e ? (@ > $x)', {x: 2}, true)).must_equal true
      @db.get(jo.path_exists_tz!('$.b.d.e ? (@ > $x)', {x: 4}, false)).must_equal false

      proc{@db.get(jo.path_match_tz!('$.b.d.e'))}.must_raise(Sequel::DatabaseError)
      proc{@db.get(jo.path_match_tz!('$.b.d.f'))}.must_raise(Sequel::DatabaseError)
      @db.get(jo.path_match_tz!('$.b.d.e', {}, true)).must_be_nil
      @db.get(jo.path_match_tz!('$.b.d.f', {}, true)).must_be_nil
      @db.get(pg_json.call('b'=>{'d'=>{'e'=>true}}).op.path_match_tz!('$.b.d.e')).must_equal true
      @db.get(pg_json.call('b'=>{'d'=>{'e'=>false}}).op.path_match_tz!('$.b.d.e')).must_equal false
      @db.get(jo.path_match_tz!('$.b.d.e > $x', '{"x":2}')).must_equal true
      @db.get(jo.path_match_tz!('$.b.d.e > $x', '{"x":4}')).must_equal false
      @db.get(jo.path_match_tz!('$.b.d.e > $x', x: 2)).must_equal true
      @db.get(jo.path_match_tz!('$.b.d.e > $x', x: 4)).must_equal false
      @db.get(jo.path_match_tz!('$.b.d.e > $x', {x: 2}, false)).must_equal true
      @db.get(jo.path_match_tz!('$.b.d.e > $x', {x: 4}, true)).must_equal false

      @db.get(jo.path_query_first_tz('$.b.d.e')).must_equal 3
      @db.get(jo.path_query_first_tz('$.b.d.f')).must_be_nil
      @db.get(jo.path_query_first_tz('$.b.d.e ? (@ > $x)', '{"x":2}')).must_equal 3
      @db.get(jo.path_query_first_tz('$.b.d.e ? (@ > $x)', '{"x":4}')).must_be_nil
      @db.get(jo.path_query_first_tz('$.b.d.e ? (@ > $x)', x: 2)).must_equal 3
      @db.get(jo.path_query_first_tz('$.b.d.e ? (@ > $x)', x: 4)).must_be_nil
      @db.get(jo.path_query_first_tz('$.b.d.e ? (@ > $x)', {x: 2}, true)).must_equal 3
      @db.get(jo.path_query_first_tz('$.b.d.e ? (@ > $x)', {x: 4}, false)).must_be_nil

      @db.get(jo.path_query_array_tz('$.b.d.e')).must_equal [3]
      @db.get(jo.path_query_array_tz('$.b.d.f')).must_equal []
      @db.get(jo.path_query_array_tz('$.b.d.e ? (@ > $x)', '{"x":2}')).must_equal [3]
      @db.get(jo.path_query_array_tz('$.b.d.e ? (@ > $x)', '{"x":4}')).must_equal []
      @db.get(jo.path_query_array_tz('$.b.d.e ? (@ > $x)', x: 2)).must_equal [3]
      @db.get(jo.path_query_array_tz('$.b.d.e ? (@ > $x)', x: 4)).must_equal []
      @db.get(jo.path_query_array_tz('$.b.d.e ? (@ > $x)', {x: 2}, true)).must_equal [3]
      @db.get(jo.path_query_array_tz('$.b.d.e ? (@ > $x)', {x: 4}, false)).must_equal []

      @db.from(jo.path_query_tz('$.b.d.e').as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query_tz('$.b.d.f').as(:a, [:b])).get(:b).must_be_nil
      @db.from(jo.path_query_tz('$.b.d.e ? (@ > $x)', '{"x":2}').as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query_tz('$.b.d.e ? (@ > $x)', '{"x":4}').as(:a, [:b])).get(:b).must_be_nil
      @db.from(jo.path_query_tz('$.b.d.e ? (@ > $x)', x: 2).as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query_tz('$.b.d.e ? (@ > $x)', x: 4).as(:a, [:b])).get(:b).must_be_nil
      @db.from(jo.path_query_tz('$.b.d.e ? (@ > $x)', {x: 2}, true).as(:a, [:b])).get(:b).must_equal 3
      @db.from(jo.path_query_tz('$.b.d.e ? (@ > $x)', {x: 4}, false).as(:a, [:b])).get(:b).must_be_nil
    end if DB.server_version >= 130000  && json_type == :jsonb

    it '14 jsonb operations/functions with pg_json_ops' do
      @db.create_table!(:items){column :i, json_type}
      @db[:items].delete
      @db[:items].insert(:i=>Sequel.pg_jsonb('a'=>{'b'=>1}))
      @db[:items].update(Sequel.pg_jsonb_op(:i)['a']['b'] => '2',
        Sequel.pg_jsonb_op(:i)['a']['c'] => '3',
        Sequel.pg_jsonb_op(Sequel[:i])['d'] => Sequel.pg_jsonb('e'=>4))
      @db[:items].all.must_equal [{:i=>{'a'=>{'b'=>2, 'c'=>3}, 'd'=>{'e'=>4}}}]
    end if DB.server_version >= 140000 && json_type == :jsonb

    it "16 #{json_type} operations/functions with pg_json_ops" do
      meth = Sequel.method(:"pg_#{json_type}_op")
      @db.get(meth.call('{}').is_json).must_equal true
      @db.get(meth.call('null').is_json).must_equal true
      @db.get(meth.call('1').is_json).must_equal true
      @db.get(meth.call('"a"').is_json).must_equal true
      @db.get(meth.call('[]').is_json).must_equal true
      @db.get(meth.call('').is_json).must_equal false

      @db.get(meth.call('1').is_json(:type=>:scalar)).must_equal true
      @db.get(meth.call('null').is_json(:type=>:value)).must_equal true
      @db.get(meth.call('{}').is_json(:type=>:object)).must_equal true
      @db.get(meth.call('{}').is_json(:type=>:array)).must_equal false
      @db.get(meth.call('{"a": 1, "a": 2}').is_json(:type=>:object, :unique=>true)).must_equal false
      @db.get(meth.call('{"a": 1, "b": 2}').is_json(:type=>:object, :unique=>true)).must_equal true
      @db.get(meth.call('[]').is_json(:type=>:object, :unique=>true)).must_equal false
      @db.get(meth.call('{"a": 1, "a": 2}').is_json(:unique=>true)).must_equal false
      @db.get(meth.call('{"a": 1, "b": 2}').is_json(:unique=>true)).must_equal true
      @db.get(meth.call('[]').is_json(:unique=>true)).must_equal true

      @db.get(meth.call('{}').is_not_json).must_equal false
      @db.get(meth.call('null').is_not_json).must_equal false
      @db.get(meth.call('1').is_not_json).must_equal false
      @db.get(meth.call('"a"').is_not_json).must_equal false
      @db.get(meth.call('[]').is_not_json).must_equal false
      @db.get(meth.call('').is_not_json).must_equal true

      @db.get(meth.call('1').is_not_json(:type=>:scalar)).must_equal false
      @db.get(meth.call('null').is_not_json(:type=>:value)).must_equal false
      @db.get(meth.call('{}').is_not_json(:type=>:object)).must_equal false
      @db.get(meth.call('{}').is_not_json(:type=>:array)).must_equal true
      @db.get(meth.call('{"a": 1, "a": 2}').is_not_json(:type=>:object, :unique=>true)).must_equal true
      @db.get(meth.call('{"a": 1, "b": 2}').is_not_json(:type=>:object, :unique=>true)).must_equal false
      @db.get(meth.call('[]').is_not_json(:type=>:object, :unique=>true)).must_equal true
      @db.get(meth.call('{"a": 1, "a": 2}').is_not_json(:unique=>true)).must_equal true
      @db.get(meth.call('{"a": 1, "b": 2}').is_not_json(:unique=>true)).must_equal false
      @db.get(meth.call('[]').is_not_json(:unique=>true)).must_equal false
    end if DB.server_version >= 160000

    it "17 #{json_type} operations/functions with pg_json_ops" do
      j = Sequel.send(:"pg_#{json_type}_op", '{"a": 1, "c": [1, 2], "n": [[1, 2], [3]], "s": "t"}')
      @db.get(j.exists('$.a')).must_equal true
      @db.get(j.exists('$.b')).must_equal false
      @db.get(j.exists('$.c')).must_equal true
      @db.get(j.exists('$.c[1]')).must_equal true
      @db.get(j.exists('$.c[3]')).must_equal false
      @db.get(j.exists('$.c[$x]', passing: {x: 1})).must_equal true
      @db.get(j.exists('$.c[$x]', passing: {x: 3})).must_equal false
      @db.get(j.exists('strict $.c[3]')).must_equal false
      @db.get(j.exists('strict $.c[3]', on_error: true)).must_equal true
      @db.get(j.exists('strict $.c[3]', on_error: false)).must_equal false
      @db.get(j.exists('strict $.c[3]', on_error: :null)).must_be_nil
      proc{@db.get(j.exists('strict $.c[3]', on_error: :error))}.must_raise Sequel::DatabaseError

      @db.get(j.value('$.a')).must_equal "1"
      @db.get(j.value('$.b')).must_be_nil
      @db.get(j.value('$.c')).must_be_nil
      @db.get(j.value('$.c[1]')).must_equal "2"
      @db.get(j.value('$.c[3]')).must_be_nil
      @db.get(j.value('$.c[$x]', passing: {x: 1})).must_equal "2"
      @db.get(j.value('$.c[$x]', passing: {x: 3})).must_be_nil
      @db.get(j.value('strict $.c[3]')).must_be_nil
      @db.get(j.value('strict $.c[3]', on_error: :null)).must_be_nil
      proc{@db.get(j.value('strict $.c[3]', on_error: :error))}.must_raise Sequel::DatabaseError
      @db.get(j.value('$.a', returning: Integer)).must_equal 1
      @db.get(j.value('$.e')).must_be_nil
      @db.get(j.value('$.a', on_empty: :null)).must_equal '1'
      @db.get(j.value('$.e', on_empty: :null)).must_be_nil
      @db.get(j.value('$.a', on_empty: 3)).must_equal '1'
      @db.get(j.value('$.e', on_empty: 3)).must_equal '3'
      @db.get(j.value('$.a', on_empty: :error)).must_equal '1'
      proc{@db.get(j.value('$.e', on_empty: :error))}.must_raise Sequel::DatabaseError

      @db.get(j.query('$.a')).must_equal 1
      @db.get(j.query('$.b')).must_be_nil
      @db.get(j.query('$.c')).must_equal [1, 2]
      @db.get(j.query('$.c[1]')).must_equal 2
      @db.get(j.query('$.c[3]')).must_be_nil
      @db.get(j.query('$.c[$x]', passing: {x: 1})).must_equal 2
      @db.get(j.query('$.c[$x]', passing: {x: 3})).must_be_nil
      @db.get(j.query('strict $.c[3]')).must_be_nil
      @db.get(j.query('strict $.c[3]', on_error: :null)).must_be_nil
      @db.get(j.query('strict $.c[3]', on_error: :empty_array)).must_equal []
      @db.get(j.query('strict $.c[3]', on_error: :empty_object)).must_equal({})
      proc{@db.get(j.query('strict $.c[3]', on_error: :error))}.must_raise Sequel::DatabaseError
      @db.get(j.query('$.a', returning: String)).must_equal '1'
      @db.get(j.query('$.a', on_empty: :null)).must_equal 1
      @db.get(j.query('$.e', on_empty: :null)).must_be_nil
      @db.get(j.query('$.e', on_empty: :empty_array)).must_equal []
      @db.get(j.query('$.e', on_empty: :empty_object)).must_equal({})
      @db.get(j.query('$.a', on_empty: '3')).must_equal 1
      @db.get(j.query('$.e', on_empty: '3')).must_equal 3
      @db.get(j.query('$.a', on_empty: :error)).must_equal 1
      proc{@db.get(j.query('$.e', on_empty: :error))}.must_raise Sequel::DatabaseError
      @db.get(j.query('$.a', :wrapper=>true)).must_equal [1]
      @db.get(j.query('$.c', :wrapper=>true)).must_equal [[1, 2]]
      @db.get(j.query('$.c[*]', :wrapper=>true)).must_equal [1, 2]
      @db.get(j.query('$.n[1]', :wrapper=>true)).must_equal [[3]]
      @db.get(j.query('$.a', :wrapper=>:conditional)).must_equal 1
      @db.get(j.query('$.c[*]', :wrapper=>:conditional)).must_equal [1, 2]
      @db.get(j.query('$.n[1]', :wrapper=>:conditional)).must_equal [3]
      @db.get(j.query('$.s', returning: String)).must_equal '"t"'
      @db.get(j.query('$.s', returning: String, :wrapper=>:omit_quotes)).must_equal "t"

      j = Sequel.send(:"pg_#{json_type}_op", (<<JSON).gsub(/\s+/, ' '))
{ "favorites" : [
   { "kind" : "comedy", "films" : [
     { "title" : "Bananas",
       "director" : "Woody Allen"},
     { "title" : "The Dinner Game",
       "director" : "Francis Veber" } ] },
   { "kind" : "horror", "films" : [
     { "title" : "Psycho",
       "director" : "Alfred Hitchcock" } ] },
   { "kind" : "thriller", "films" : [
     { "title" : "Vertigo",
       "director" : "Alfred Hitchcock" } ] },
   { "kind" : "drama", "films" : [
     { "title" : "Yojimbo",
       "director" : "Akira Kurosawa" } ] }
  ] }
JSON

      @db.from(j.table('$.favorites[*]') do
        ordinality :id
        String :kind
        String :title, path: '$.films[*].title', :wrapper=>true
        String :director, path: '$.films[*].director', :wrapper=>true
      end).all.must_equal [
        {:id=>1, :kind=>"comedy", :title=>'["Bananas", "The Dinner Game"]', :director=>'["Woody Allen", "Francis Veber"]'},
        {:id=>2, :kind=>"horror", :title=>'["Psycho"]', :director=>'["Alfred Hitchcock"]'},
        {:id=>3, :kind=>"thriller", :title=>'["Vertigo"]', :director=>'["Alfred Hitchcock"]'},
        {:id=>4, :kind=>"drama", :title=>'["Yojimbo"]', :director=>'["Akira Kurosawa"]'}
      ]

      @db.from(j.table('$.favorites[*] ? (@.films[*].director == $filter)', :passing=>{:filter=>'Alfred Hitchcock'}) do
        ordinality :id
        String :kind, path: '$.kind'
        String :title, path: '$.films[*].title', :wrapper=>:omit_quotes, :format=>:json
        String :director, path: '$.films[*].director', :wrapper=>:keep_quotes
      end).all.must_equal [
        {:id=>1, :kind=>"horror", :title=>'Psycho', :director=>'"Alfred Hitchcock"'},
        {:id=>2, :kind=>"thriller", :title=>'Vertigo', :director=>'"Alfred Hitchcock"'},
      ]

      @db.from(j.table('$.favorites[*] ? (@.films[*].director == $filter)', :passing=>{:filter=>'Alfred Hitchcock'}) do
        ordinality :id
        String :kind, path: '$.kind'
        nested '$.films[*]' do
          String :title, path: '$.title', :wrapper=>:omit_quotes, :format=>:json
          String :director, path: '$.director', :wrapper=>:keep_quotes
        end
      end).all.must_equal [
        {:id=>1, :kind=>"horror", :title=>'Psycho', :director=>'"Alfred Hitchcock"'},
        {:id=>2, :kind=>"thriller", :title=>'Vertigo', :director=>'"Alfred Hitchcock"'},
      ]

      @db.from(j.table('$.favorites[*]') do
        ordinality :id
        String :kind, path: '$.kind'
        nested '$.films[*]' do
          String :title, path: '$.title', :wrapper=>:omit_quotes, :format=>:json
          String :director, path: '$.director', :wrapper=>:keep_quotes
        end
      end).all.must_equal [
        {:id=>1, :kind=>"comedy", :title=>'Bananas', :director=>'"Woody Allen"'},
        {:id=>1, :kind=>"comedy", :title=>'The Dinner Game', :director=>'"Francis Veber"'},
        {:id=>2, :kind=>"horror", :title=>'Psycho', :director=>'"Alfred Hitchcock"'},
        {:id=>3, :kind=>"thriller", :title=>'Vertigo', :director=>'"Alfred Hitchcock"'},
        {:id=>4, :kind=>"drama", :title=>'Yojimbo', :director=>'"Akira Kurosawa"'}
      ]

      j = Sequel.send(:"pg_#{json_type}_op", (<<JSON).gsub(/\s+/, ' '))
{"favorites":
    {"movies":
      [{"name": "One", "director": "John Doe"},
       {"name": "Two", "director": "Don Joe"}],
     "books":
      [{"name": "Mystery", "authors": [{"name": "Brown Dan"}]},
       {"name": "Wonder", "authors": [{"name": "Jun Murakami"}, {"name":"Craig Doe"}]}]
}}
JSON
      @db.from(j.table('$.favorites[*]') do
        ordinality :user_id
        nested '$.movies[*]' do
          ordinality :movie_id
          String :mname, path: '$.name'
          String :director
        end
        nested '$.books[*]' do
          ordinality :book_id
          String :bname, path: '$.name'
          nested '$.authors[*]' do
            ordinality :author_id
            String :author_name, path: '$.name'
          end
        end
      end).all.must_equal [
        {:user_id=>1, :movie_id=>1, :mname=>"One", :director=>"John Doe", :book_id=>nil, :bname=>nil, :author_id=>nil, :author_name=>nil},
        {:user_id=>1, :movie_id=>2, :mname=>"Two", :director=>"Don Joe", :book_id=>nil, :bname=>nil, :author_id=>nil, :author_name=>nil},
        {:user_id=>1, :movie_id=>nil, :mname=>nil, :director=>nil, :book_id=>1, :bname=>"Mystery", :author_id=>1, :author_name=>"Brown Dan"},
        {:user_id=>1, :movie_id=>nil, :mname=>nil, :director=>nil, :book_id=>2, :bname=>"Wonder", :author_id=>1, :author_name=>"Jun Murakami"},
        {:user_id=>1, :movie_id=>nil, :mname=>nil, :director=>nil, :book_id=>2, :bname=>"Wonder", :author_id=>2, :author_name=>"Craig Doe"}
      ]

      proc do
        @db.from(j.table('strict $.x[0].y', :on_error=>:error) do
          ordinality :id
        end).all
      end.must_raise Sequel::DatabaseError

      @db.from(j.table('strict $.x[0].y', :on_error=>:empty_array) do
        ordinality :id
      end).all.must_equal []

      @db.from(j.table('strict $.x[0].y') do
        ordinality :id
      end).all.must_equal []

      proc do
        @db.from(j.table('$.favorites[*]') do
          String :foo, path: 'strict $.foo', :on_error=>:error
        end).all.must_equal []
      end.must_raise Sequel::DatabaseError

      @db.from(j.table('$.favorites[*]') do
        String :foo, path: 'strict $.foo', :on_error=>:null
      end).all.must_equal [{:foo=>nil}]

      @db.from(j.table('$.favorites[*]') do
        column :foo, json_type, path: 'strict $.foo', :on_error=>:empty_object, :format=>:json, :wrapper=>:conditional
      end).all.must_equal [{:foo=>{}}]

      @db.from(j.table('$.favorites[*]') do
        column :foo, json_type, path: 'strict $.foo', :on_error=>:empty_array, :format=>:json
      end).all.must_equal [{:foo=>[]}]

      @db.from(j.table('$.favorites[*]') do
        Integer :foo, path: 'strict $.foo', :on_error=>42
      end).all.must_equal [{:foo=>42}]

      proc do
        @db.from(j.table('$.favorites[*]') do
          String :foo, path: '$.foo', :on_empty=>:error
        end).all.must_equal []
      end.must_raise Sequel::DatabaseError

      @db.from(j.table('$.favorites[*]') do
        String :foo, path: '$.foo', :on_empty=>:null
      end).all.must_equal [{:foo=>nil}]

      @db.from(j.table('$.favorites[*]') do
        column :foo, json_type, path: '$.foo', :on_empty=>:empty_object, :format=>:json
      end).all.must_equal [{:foo=>{}}]

      @db.from(j.table('$.favorites[*]') do
        column :foo, json_type, path: '$.foo', :on_empty=>:empty_array, :format=>:json
      end).all.must_equal [{:foo=>[]}]

      @db.from(j.table('$.favorites[*]') do
        Integer :foo, path: '$.foo', :on_empty=>42
      end).all.must_equal [{:foo=>42}]

      @db.from(j.table('$.favorites[*]') do
        exists :foo, TrueClass
      end).all.must_equal [{:foo=>false}]

      @db.from(j.table('$.favorites[*]') do
        exists :foo, TrueClass, path: 'strict $.foo', :on_error=>true
      end).all.must_equal [{:foo=>true}]

      @db.from(j.table('$.favorites[*]') do
        exists :foo, TrueClass, path: 'strict $.foo', :on_error=>false
      end).all.must_equal [{:foo=>false}]

      @db.from(j.table('$.favorites[*]') do
        exists :foo, String, path: 'strict $.foo', :on_error=>:null
      end).all.must_equal [{:foo=>nil}]

      proc do
        @db.from(j.table('$.favorites[*]') do
          exists :foo, String, path: 'strict $.foo', :on_error=>:error
        end).all.must_equal [{:foo=>true}]
      end.must_raise Sequel::DatabaseError

      j = Sequel.send(:"pg_#{json_type}_op", '{"a":{"n": [{"b": 3}]}}')
      @db.from(j.table('$.a'){column :j, json_type, :path=>'$.n[0]', :format=>:json, :wrapper=>true}).all.must_equal [{:j=>[{"b"=>3}]}]
      @db.from(j.table('$.a'){column :j, json_type, :path=>'$.n[0]', :format=>:json, :wrapper=>:conditional}).all.must_equal [{:j=>{"b"=>3}}]

      @db.from(j.table(Sequel['$.a.n'].as(:foo)){Integer :b}).all.must_equal [{:b=>3}]
      @db.from(j.table(Sequel['$.a'].as(:foo)){nested(Sequel['$.n'].as(:c)){Integer :b}}).all.must_equal [{:b=>3}]
    end if DB.server_version >= 170000
  end
end if DB.server_version >= 90200

describe 'PostgreSQL inet/cidr types' do
  ipv6_broken = (IPAddr.new('::1'); false) rescue true

  before(:all) do
    @db = DB
    @ds = @db[:items]
    @v4 = '127.0.0.1'
    @v4nm = '127.0.0.0/8'
    @v6 = '2001:4f8:3:ba:2e0:81ff:fe22:d1f1'
    @v6nm = '2001:4f8:3:ba::/64'
    @ipv4 = IPAddr.new(@v4)
    @ipv4nm = IPAddr.new(@v4nm)
    unless ipv6_broken
      @ipv6 = IPAddr.new(@v6)
      @ipv6nm = IPAddr.new(@v6nm)
    end
  end
  after do
    @db.drop_table?(:items)
  end

  it 'insert and retrieve inet/cidr values' do
    @db.create_table!(:items){inet :i; cidr :c}
    @ds.insert(@ipv4, @ipv4nm)
    @ds.count.must_equal 1
    rs = @ds.all
    rs.first[:i].must_equal @ipv4
    rs.first[:c].must_equal @ipv4nm
    rs.first[:i].must_be_kind_of(IPAddr)
    rs.first[:c].must_be_kind_of(IPAddr)
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    unless ipv6_broken
      @ds.delete
      @ds.insert(@ipv6, @ipv6nm)
      @ds.count.must_equal 1
      rs = @ds.all
      rs.first[:j]
      rs.first[:i].must_equal @ipv6
      rs.first[:c].must_equal @ipv6nm
      rs.first[:i].must_be_kind_of(IPAddr)
      rs.first[:c].must_be_kind_of(IPAddr)
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs
    end
  end

  it 'allow overridding type conversions of inet/cidr types' do
    cp = @db.conversion_procs[869]
    acp = @db.conversion_procs[1041]
    begin
      @db.add_conversion_proc(1041, lambda{|s| s})
      @db.add_conversion_proc(869, lambda{|s| s})
      @db.get(Sequel.cast('127.0.0.1', :inet)).must_equal '127.0.0.1'
      @db.get(Sequel.pg_array(['127.0.0.1'], :inet)).must_equal '{127.0.0.1}'
    ensure
      @db.add_conversion_proc(869, cp)
      @db.add_conversion_proc(1041, acp)
    end
  end

  it 'insert and retrieve inet/cidr/macaddr array values' do
    @db.create_table!(:items){column :i, 'inet[]'; column :c, 'cidr[]'; column :m, 'macaddr[]'}
    @ds.insert(Sequel.pg_array([@ipv4], 'inet'), Sequel.pg_array([@ipv4nm], 'cidr'), Sequel.pg_array(['12:34:56:78:90:ab'], 'macaddr'))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.first.values.all?{|c| c.is_a?(Sequel::Postgres::PGArray)}.must_equal true
    rs.first[:i].first.must_equal @ipv4
    rs.first[:c].first.must_equal @ipv4nm
    rs.first[:m].first.must_equal '12:34:56:78:90:ab'
    rs.first[:i].first.must_be_kind_of(IPAddr)
    rs.first[:c].first.must_be_kind_of(IPAddr)
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'use ipaddr in bound variables' do
    @db.create_table!(:items){inet :i; cidr :c}

    @ds.call(:insert, {:i=>@ipv4, :c=>@ipv4nm}, {:i=>:$i, :c=>:$c})
    @ds.get(:i).must_equal @ipv4
    @ds.get(:c).must_equal @ipv4nm
    @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv4, :c=>@ipv4nm).must_equal(:i=>@ipv4, :c=>@ipv4nm)
    @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv6, :c=>@ipv6nm).must_be_nil
    @ds.filter(:i=>:$i, :c=>:$c).call(:delete, :i=>@ipv4, :c=>@ipv4nm).must_equal 1

    unless ipv6_broken
      @ds.call(:insert, {:i=>@ipv6, :c=>@ipv6nm}, {:i=>:$i, :c=>:$c})
      @ds.get(:i).must_equal @ipv6
      @ds.get(:c).must_equal @ipv6nm
      @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv6, :c=>@ipv6nm).must_equal(:i=>@ipv6, :c=>@ipv6nm)
      @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv4, :c=>@ipv4nm).must_be_nil
      @ds.filter(:i=>:$i, :c=>:$c).call(:delete, :i=>@ipv6, :c=>@ipv6nm).must_equal 1
    end

    @db.create_table!(:items){column :i, 'inet[]'; column :c, 'cidr[]'; column :m, 'macaddr[]'}
    @ds.call(:insert, {:i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab']}, {:i=>:$i, :c=>:$c, :m=>:$m})
    @ds.filter(:i=>:$i, :c=>:$c, :m=>:$m).call(:first, :i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab']).must_equal(:i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab'])
    @ds.filter(:i=>:$i, :c=>:$c, :m=>:$m).call(:first, :i=>[], :c=>[], :m=>[]).must_be_nil
    @ds.filter(:i=>:$i, :c=>:$c, :m=>:$m).call(:delete, :i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab']).must_equal 1
  end if uses_pg_or_jdbc

  it 'parse default values for schema' do
    @db.create_table!(:items) do
      inet :i, :default=>IPAddr.new('127.0.0.1')
      cidr :c, :default=>IPAddr.new('127.0.0.1')
    end
    @db.schema(:items)[0][1][:ruby_default].must_equal IPAddr.new('127.0.0.1')
    @db.schema(:items)[1][1][:ruby_default].must_equal IPAddr.new('127.0.0.1')
  end

  it 'with models' do
    @db.create_table!(:items) do
      primary_key :id
      inet :i
      cidr :c
    end
    c = Class.new(Sequel::Model(@db[:items]))
    c.create(:i=>@v4, :c=>@v4nm).values.values_at(:i, :c).must_equal [@ipv4, @ipv4nm]
    unless ipv6_broken
      c.create(:i=>@ipv6, :c=>@ipv6nm).values.values_at(:i, :c).must_equal [@ipv6, @ipv6nm]
    end
  end

  it 'operations/functions with pg_inet_ops' do
    Sequel.extension :pg_inet_ops

    @db.get(Sequel.pg_inet_op('1.2.3.4') << '1.2.3.0/24').must_equal true
    @db.get(Sequel.pg_inet_op('1.2.3.4') << '1.2.3.4/32').must_equal false
    @db.get(Sequel.pg_inet_op('1.2.3.4') << '1.2.2.0/24').must_equal false
    @db.get(Sequel.pg_inet_op('1.2.3.4').contained_by('1.2.3.0/24')).must_equal true
    @db.get(Sequel.pg_inet_op('1.2.3.4').contained_by('1.2.3.4/32')).must_equal false
    @db.get(Sequel.pg_inet_op('1.2.3.4').contained_by('1.2.2.0/24')).must_equal false

    @db.get(Sequel.pg_inet_op('1.2.3.4').contained_by_or_equals('1.2.3.0/24')).must_equal true
    @db.get(Sequel.pg_inet_op('1.2.3.4').contained_by_or_equals('1.2.3.4/32')).must_equal true
    @db.get(Sequel.pg_inet_op('1.2.3.4').contained_by_or_equals('1.2.2.0/24')).must_equal false

    @db.get(Sequel.pg_inet_op('1.2.3.0/24') >> '1.2.3.4').must_equal true
    @db.get(Sequel.pg_inet_op('1.2.3.0/24') >> '1.2.2.4').must_equal false
    @db.get(Sequel.pg_inet_op('1.2.3.0/24').contains('1.2.3.4')).must_equal true
    @db.get(Sequel.pg_inet_op('1.2.3.0/24').contains('1.2.2.4')).must_equal false

    @db.get(Sequel.pg_inet_op('1.2.3.0/24').contains_or_equals('1.2.3.4')).must_equal true
    @db.get(Sequel.pg_inet_op('1.2.3.0/24').contains_or_equals('1.2.2.4')).must_equal false
    @db.get(Sequel.pg_inet_op('1.2.3.0/24').contains_or_equals('1.2.3.0/24')).must_equal true

    @db.get(Sequel.pg_inet_op('1.2.3.0/32') + 1).must_equal IPAddr.new('1.2.3.1/32')
    @db.get(Sequel.pg_inet_op('1.2.3.1/32') - 1).must_equal IPAddr.new('1.2.3.0/32')
    @db.get(Sequel.pg_inet_op('1.2.3.1/32') - '1.2.3.0/32').must_equal 1
    @db.get(Sequel.pg_inet_op('1.2.3.0/32') & '1.2.0.4/32').must_equal IPAddr.new('1.2.0.0/32')
    @db.get(Sequel.pg_inet_op('1.2.0.0/32') | '0.0.3.4/32').must_equal IPAddr.new('1.2.3.4/32')
    @db.get(~Sequel.pg_inet_op('0.0.0.0/32')).must_equal IPAddr.new('255.255.255.255/32')

    @db.get(Sequel.pg_inet_op('1.2.3.4/24').abbrev).must_equal '1.2.3.4/24'
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').broadcast).must_equal IPAddr.new('1.2.3.255/24')
    @db.get(Sequel.pg_inet_op('1234:3456:5678:789a:9abc:bced:edf0:f012/96').broadcast).must_equal IPAddr.new('1234:3456:5678:789a:9abc:bced::/96')
    @db.get(Sequel.pg_inet_op('1234:3456:5678:789a:9abc:bced:edf0:f012/128').broadcast).must_equal IPAddr.new('1234:3456:5678:789a:9abc:bced:edf0:f012/128')
    @db.get(Sequel.pg_inet_op('1234:3456:5678:789a:9abc:bced:edf0:f012/64').broadcast).must_equal IPAddr.new('1234:3456:5678:789a::/64')
    @db.get(Sequel.pg_inet_op('1234:3456:5678:789a:9abc:bced:edf0:f012/32').broadcast).must_equal IPAddr.new('1234:3456::/32')
    @db.get(Sequel.pg_inet_op('1234:3456:5678:789a:9abc:bced:edf0:f012/0').broadcast).must_equal IPAddr.new('::/0')
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').family).must_equal 4
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').host).must_equal '1.2.3.4'
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').hostmask).must_equal IPAddr.new('0.0.0.255/32')
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').masklen).must_equal 24
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').netmask).must_equal IPAddr.new('255.255.255.0/32')
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').network).must_equal IPAddr.new('1.2.3.0/24')
    @db.get(Sequel.pg_inet_op('1.2.3.4/24').set_masklen(16)).must_equal IPAddr.new('1.2.3.4/16')
    @db.get(Sequel.pg_inet_op('1.2.3.4/32').text).must_equal '1.2.3.4/32'

    if @db.server_version >= 90400
      @db.get(Sequel.pg_inet_op('1.2.3.0/24').contains_or_contained_by('1.2.0.0/16')).must_equal true
      @db.get(Sequel.pg_inet_op('1.2.0.0/16').contains_or_contained_by('1.2.3.0/24')).must_equal true
      @db.get(Sequel.pg_inet_op('1.3.0.0/16').contains_or_contained_by('1.2.3.0/24')).must_equal false
    end
  end
end

describe 'PostgreSQL custom range types' do
  after do
    @db.run "DROP TYPE timerange";
  end

  it "should allow registration and use" do
    @db = DB
    @db.run "CREATE TYPE timerange AS range (subtype = time)"
    @db.register_range_type('timerange')
    r = Sequel::SQLTime.create(10, 11, 12)..Sequel::SQLTime.create(11, 12, 13)
    @db.get(Sequel.pg_range(r, :timerange)).to_range.must_equal r

    if DB.server_version >= 140000
      @db.register_multirange_type('timemultirange')
      r = [Sequel::SQLTime.create(1, 2, 3)..Sequel::SQLTime.create(7, 8, 9), Sequel::SQLTime.create(10, 11, 12)..Sequel::SQLTime.create(11, 12, 13)]
      @db.get(Sequel.pg_multirange(r, :timemultirange)).map(&:to_range).must_equal r
    end
  end
end if DB.server_version >= 90200

describe 'PostgreSQL range types' do
  before(:all) do
    @db = DB
    @ds = @db[:items]
    @map = {:i4=>'int4range', :i8=>'int8range', :n=>'numrange', :d=>'daterange', :t=>'tsrange', :tz=>'tstzrange'}
    @r = {:i4=>1...2, :i8=>2...3, :n=>BigDecimal('1.0')..BigDecimal('2.0'), :d=>Date.today...(Date.today+1), :t=>Time.local(2011, 1)..Time.local(2011, 2), :tz=>Time.local(2011, 1)..Time.local(2011, 2)}
    @ra = {}
    @pgr = {}
    @pgra = {}
    @r.each{|k, v| @ra[k] = Sequel.pg_array([v], @map[k])}
    @r.each{|k, v| @pgr[k] = Sequel.pg_range(v)}
    @r.each{|k, v| @pgra[k] = Sequel.pg_array([Sequel.pg_range(v)], @map[k])}
  end
  after do
    @db.drop_table?(:items)
  end

  it 'insert and retrieve range type values' do
    @db.create_table!(:items){int4range :i4; int8range :i8; numrange :n; daterange :d; tsrange :t; tstzrange :tz}
    [@r, @pgr].each do |input|
      h = {}
      input.each{|k, v| h[k] = Sequel.cast(v, @map[k])}
      @ds.insert(h)
      @ds.count.must_equal 1
      rs = @ds.all
      rs.first.each do |k, v|
        v.class.must_equal(Sequel::Postgres::PGRange)
        v.to_range.must_be_kind_of(Range)
        v.must_be :==, @r[k]
        v.to_range.must_equal @r[k]
      end
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs
      @ds.delete
    end
  end

  it 'insert and retrieve arrays of range type values' do
    @db.create_table!(:items){column :i4, 'int4range[]'; column :i8, 'int8range[]'; column :n, 'numrange[]'; column :d, 'daterange[]'; column :t, 'tsrange[]'; column :tz, 'tstzrange[]'}
    [@ra, @pgra].each do |input|
      @ds.insert(input)
      @ds.count.must_equal 1
      rs = @ds.all
      rs.first.each do |k, v|
        v.class.must_equal(Sequel::Postgres::PGArray)
        v.to_a.must_be_kind_of(Array)
        v.first.class.must_equal(Sequel::Postgres::PGRange)
        v.first.to_range.must_be_kind_of(Range)
        v.must_be :==, @ra[k].to_a
        v.first.must_be :==, @r[k]
      end
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs
      @ds.delete
    end
  end

  it 'use range types in bound variables' do
    @db.create_table!(:items){int4range :i4; int8range :i8; numrange :n; daterange :d; tsrange :t; tstzrange :tz}
    h = {}
    @r.keys.each{|k| h[k] = :"$#{k}"}
    r2 = {}
    @r.each{|k, v| r2[k] = Range.new(v.begin, v.end+2)}
    @ds.call(:insert, @r, h)
    @ds.first.must_be :==, @r
    @ds.filter(h).call(:first, @r).must_be :==, @r
    @ds.filter(h).call(:first, @pgr).must_be :==, @r
    @ds.filter(h).call(:first, r2).must_be_nil
    @ds.filter(h).call(:delete, @r).must_equal 1

    @db.create_table!(:items){column :i4, 'int4range[]'; column :i8, 'int8range[]'; column :n, 'numrange[]'; column :d, 'daterange[]'; column :t, 'tsrange[]'; column :tz, 'tstzrange[]'}
    @r.each{|k, v| r2[k] = [Range.new(v.begin, v.end+2)]}
    @ds.call(:insert, @ra, h)
    @ds.filter(h).call(:first, @ra).each{|k, v| v.must_be :==, @ra[k].to_a}
    @ds.filter(h).call(:first, @pgra).each{|k, v| v.must_be :==, @ra[k].to_a}
    @ds.filter(h).call(:first, r2).must_be_nil
    @ds.filter(h).call(:delete, @ra).must_equal 1
  end if uses_pg_or_jdbc

  it 'handle endless ranges' do
    @db.get(Sequel.cast(eval('(1...)'), :int4range)).must_be :==, eval('(1...)')
    @db.get(Sequel.cast(eval('(1...)'), :int4range)).wont_be :==, eval('(2...)')
    @db.get(Sequel.cast(eval('(1...)'), :int4range)).wont_be :==, eval('(1..)')
    @db.get(Sequel.cast(eval('(2...)'), :int4range)).must_be :==, eval('(2...)')
    @db.get(Sequel.cast(eval('(2...)'), :int4range)).wont_be :==, eval('(2..)')
    @db.get(Sequel.cast(eval('(2...)'), :int4range)).wont_be :==, eval('(1...)')
  end if RUBY_VERSION >= '2.6'

  it 'handle startless ranges' do
    @db.get(Sequel.cast(eval('(...1)'), :int4range)).must_be :==, Sequel::Postgres::PGRange.new(nil, 1, :exclude_begin=>true, :exclude_end=>true, :db_type=>"int4range")
    @db.get(Sequel.cast(eval('(...1)'), :int4range)).wont_be :==, Sequel::Postgres::PGRange.new(nil, 2, :exclude_begin=>true, :exclude_end=>true, :db_type=>"int4range")
    @db.get(Sequel.cast(eval('(...1)'), :int4range)).wont_be :==, Sequel::Postgres::PGRange.new(nil, 1, :exclude_end=>true, :db_type=>"int4range")
    @db.get(Sequel.cast(eval('(...1)'), :int4range)).wont_be :==, Sequel::Postgres::PGRange.new(nil, 1, :exclude_begin=>true, :db_type=>"int4range")
  end if RUBY_VERSION >= '2.7'

  it 'handle startless, endless ranges' do
    @db.get(Sequel.cast(eval('nil...nil'), :int4range)).must_be :==, Sequel::Postgres::PGRange.new(nil, nil, :exclude_begin=>true, :exclude_end=>true, :db_type=>"int4range")
    @db.get(Sequel.cast(eval('nil...nil'), :int4range)).wont_be :==, Sequel::Postgres::PGRange.new(nil, nil, :exclude_begin=>true, :db_type=>"int4range")
    @db.get(Sequel.cast(eval('nil...nil'), :int4range)).wont_be :==, Sequel::Postgres::PGRange.new(nil, nil, :exclude_end=>true, :db_type=>"int4range")
    @db.get(Sequel.cast(eval('nil...nil'), :int4range)).wont_be :==, Sequel::Postgres::PGRange.new(1, nil, :exclude_begin=>true, :db_type=>"int4range")
    @db.get(Sequel.cast(eval('nil...nil'), :int4range)).wont_be :==, Sequel::Postgres::PGRange.new(nil, 1, :exclude_begin=>true, :db_type=>"int4range")
  end if RUBY_VERSION >= '2.7'

  it 'parse default values for schema' do
    @db.create_table!(:items) do
      Integer :j
      int4range :i, :default=>1..4
    end
    @db.schema(:items)[0][1][:ruby_default].must_be_nil
    @db.schema(:items)[1][1][:ruby_default].must_equal Sequel::Postgres::PGRange.new(1, 5, :exclude_end=>true, :db_type=>'int4range')
  end

  it 'with models' do
    @db.create_table!(:items){primary_key :id; int4range :i4; int8range :i8; numrange :n; daterange :d; tsrange :t; tstzrange :tz}
    c = Class.new(Sequel::Model(@db[:items]))
    v = c.create(@r).values
    v.delete(:id)
    v.must_be :==, @r

    @db.create_table!(:items){primary_key :id; column :i4, 'int4range[]'; column :i8, 'int8range[]'; column :n, 'numrange[]'; column :d, 'daterange[]'; column :t, 'tsrange[]'; column :tz, 'tstzrange[]'}
    c = Class.new(Sequel::Model(@db[:items]))
    v = c.create(@ra).values
    v.delete(:id)
    v.each{|k,v1| v1.must_be :==, @ra[k].to_a}
  end

  it 'works with current_datetime_timestamp extension' do
    ds = @db.dataset.extension(:current_datetime_timestamp)
    tsr = ds.get(Sequel.pg_range(ds.current_datetime..ds.current_datetime, :tstzrange))
    tsr.begin.must_be_kind_of Time
    tsr.end.must_be_kind_of Time
  end

  it 'operations/functions with pg_range_ops' do
    Sequel.extension :pg_range_ops

    @db.get(Sequel.pg_range(1..5, :int4range).op.contains(2..4)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.contains(3..6)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.contains(0..6)).must_equal false

    @db.get(Sequel.pg_range(1..5, :int4range).op.contained_by(0..6)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.contained_by(3..6)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.contained_by(2..4)).must_equal false

    @db.get(Sequel.pg_range(1..5, :int4range).op.overlaps(5..6)).must_equal true
    @db.get(Sequel.pg_range(1...5, :int4range).op.overlaps(5..6)).must_equal false
    
    @db.get(Sequel.pg_range(1..5, :int4range).op.left_of(6..10)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.left_of(5..10)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.left_of(-1..0)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.left_of(-1..3)).must_equal false

    @db.get(Sequel.pg_range(1..5, :int4range).op.right_of(6..10)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.right_of(5..10)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.right_of(-1..0)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.right_of(-1..3)).must_equal false

    @db.get(Sequel.pg_range(1..5, :int4range).op.ends_before(6..10)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.ends_before(5..10)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.ends_before(-1..0)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.ends_before(-1..3)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.ends_before(-1..7)).must_equal true

    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(6..10)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(5..10)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(3..10)).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(-1..10)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(-1..0)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(-1..3)).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(-5..-1)).must_equal true

    @db.get(Sequel.pg_range(1..5, :int4range).op.adjacent_to(6..10)).must_equal true
    @db.get(Sequel.pg_range(1...5, :int4range).op.adjacent_to(6..10)).must_equal false

    @db.get((Sequel.pg_range(1..5, :int4range).op + (6..10)).adjacent_to(6..10)).must_equal false
    @db.get((Sequel.pg_range(1..5, :int4range).op + (6..10)).adjacent_to(11..20)).must_equal true

    @db.get((Sequel.pg_range(1..5, :int4range).op * (2..6)).adjacent_to(6..10)).must_equal true
    @db.get((Sequel.pg_range(1..4, :int4range).op * (2..6)).adjacent_to(6..10)).must_equal false

    @db.get((Sequel.pg_range(1..5, :int4range).op - (2..6)).adjacent_to(2..10)).must_equal true
    @db.get((Sequel.pg_range(0..4, :int4range).op - (3..6)).adjacent_to(4..10)).must_equal false

    @db.get(Sequel.pg_range(0..4, :int4range).op.lower).must_equal 0
    @db.get(Sequel.pg_range(0..4, :int4range).op.upper).must_equal 5

    @db.get(Sequel.pg_range(0..4, :int4range).op.isempty).must_equal false
    @db.get(Sequel::Postgres::PGRange.empty(:int4range).op.isempty).must_equal true

    @db.get(Sequel.pg_range(1..5, :numrange).op.lower_inc).must_equal true
    @db.get(Sequel::Postgres::PGRange.new(1, 5, :exclude_begin=>true, :db_type=>:numrange).op.lower_inc).must_equal false

    @db.get(Sequel.pg_range(1..5, :numrange).op.upper_inc).must_equal true
    @db.get(Sequel.pg_range(1...5, :numrange).op.upper_inc).must_equal false

    @db.get(Sequel::Postgres::PGRange.new(1, 5, :db_type=>:int4range).op.lower_inf).must_equal false
    @db.get(Sequel::Postgres::PGRange.new(nil, 5, :db_type=>:int4range).op.lower_inf).must_equal true

    @db.get(Sequel::Postgres::PGRange.new(1, 5, :db_type=>:int4range).op.upper_inf).must_equal false
    @db.get(Sequel::Postgres::PGRange.new(1, nil, :db_type=>:int4range).op.upper_inf).must_equal true
  end
end if DB.server_version >= 90200

describe 'PostgreSQL multirange types' do
  before(:all) do
    @db = DB
    @ds = @db[:items]
    @map = {:i4=>'int4multirange', :i8=>'int8multirange', :n=>'nummultirange', :d=>'datemultirange', :t=>'tsmultirange', :tz=>'tstzmultirange'}
    @r = {
      :i4=>[1...2, 4...5],
      :i8=>[2...3, 5...6],
      :n=>[BigDecimal('1.0')..BigDecimal('2.0'), BigDecimal('4.0')..BigDecimal('5.0')],
      :d=>[Date.today...(Date.today+1), (Date.today+3)...(Date.today+4)],
      :t=>[Time.local(2011, 1)..Time.local(2011, 2), Time.local(2011, 4)..Time.local(2011, 5)],
      :tz=>[Time.local(2011, 1)..Time.local(2011, 2), Time.local(2011, 4)..Time.local(2011, 5)],
    }
    @pgr = {}
    @pgra = {}
    @r.each do |k, v|
      type = @map[k]
      val = @pgr[k] = Sequel.pg_multirange(v.map{|range| Sequel::Postgres::PGRange.new(range.begin, range.end, :exclude_end => range.exclude_end?, :db_type => type.sub('multi', ''))}, type)
      @pgra[k] = Sequel.pg_array([val], type)
    end
  end
  after do
    @db.drop_table?(:items)
  end

  it 'insert and retrieve multirange type values' do
    @db.create_table!(:items){int4multirange :i4; int8multirange :i8; nummultirange :n; datemultirange :d; tsmultirange :t; tstzmultirange :tz}
    h = {}
    @pgr.each{|k, v| h[k] = Sequel.cast(v, @map[k])}
    @ds.insert(h)
    @ds.count.must_equal 1
    rs = @ds.all
    rs.first.each do |k, v|
      v.class.must_equal(Sequel::Postgres::PGMultiRange)
      v.each{|range| range.must_be_kind_of(Sequel::Postgres::PGRange)}
      v.must_be :==, @r[k]
    end
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
    @ds.delete
  end

  it 'insert and retrieve arrays of multirange type values' do
    @db.create_table!(:items){column :i4, 'int4multirange[]'; column :i8, 'int8multirange[]'; column :n, 'nummultirange[]'; column :d, 'datemultirange[]'; column :t, 'tsmultirange[]'; column :tz, 'tstzmultirange[]'}
    @ds.insert(@pgra)
    @ds.count.must_equal 1
    rs = @ds.all
    rs.first.each do |k, v|
      v.class.must_equal(Sequel::Postgres::PGArray)
      v.to_a.must_be_kind_of(Array)
      v.first.class.must_equal(Sequel::Postgres::PGMultiRange)
      v.first.first.class.must_equal(Sequel::Postgres::PGRange)
      v.first.first.to_range.must_be_kind_of(Range)
      v.must_be :==, @pgra[k]
      v.first.must_be :==, @pgr[k]
      v.first.must_be :==, @r[k]
    end
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
    @ds.delete
  end

  it 'use multirange types in bound variables' do
    @db.create_table!(:items){int4multirange :i4; int8multirange :i8; nummultirange :n; datemultirange :d; tsmultirange :t; tstzmultirange :tz}
    h = {}
    @r.keys.each{|k| h[k] = :"$#{k}"}
    r2 = {}
    @r.each{|k, v| r2[k] = Sequel.pg_multirange(v.map{|range| Range.new(range.begin+2, range.end+2)}, @map[k])}
    @ds.call(:insert, @pgr, h)
    @ds.first.must_be :==, @r
    @ds.filter(h).call(:first, @pgr).must_be :==, @r
    @ds.filter(h).call(:first, r2).must_be_nil
    @ds.filter(h).call(:delete, @pgr).must_equal 1

    @db.create_table!(:items){column :i4, 'int4multirange[]'; column :i8, 'int8multirange[]'; column :n, 'nummultirange[]'; column :d, 'datemultirange[]'; column :t, 'tsmultirange[]'; column :tz, 'tstzmultirange[]'}
    @r.each{|k, v| r2[k] = Sequel.pg_array([Sequel.pg_multirange(v.map{|range| Range.new(range.begin+2, range.end+2)}, @map[k])])}
    @ds.call(:insert, @pgra, h)
    @ds.filter(h).call(:first, @pgra).each{|k, v| v.must_be :==, @pgra[k].to_a}
    @ds.filter(h).call(:first, r2).must_be_nil
    @ds.filter(h).call(:delete, @pgra).must_equal 1
  end if uses_pg_or_jdbc

  it 'parse multiranges containing empty ranges' do
    @db.get(Sequel::Postgres::PGMultiRange.new([], 'int4multirange')).must_be_empty
    @db.get(Sequel::Postgres::PGMultiRange.new([Sequel::Postgres::PGRange.empty('int4range')], 'int4multirange')).must_be_empty
  end

  it 'parse default values for schema' do
    @db.create_table!(:items) do
      Integer :j
      int4multirange :i, :default=>Sequel.pg_multirange([1..4], :int4multirange)
    end
    @db.schema(:items)[0][1][:ruby_default].must_be_nil
    @db.schema(:items)[1][1][:ruby_default].must_equal Sequel::Postgres::PGMultiRange.new([Sequel::Postgres::PGRange.new(1, 5, :exclude_end=>true, :db_type=>'int4range')], 'int4multirange')
    @db.schema(:items)[1][1][:ruby_default].first.must_equal Sequel::Postgres::PGRange.new(1, 5, :exclude_end=>true, :db_type=>'int4range')
  end

  it 'with models' do
    @db.create_table!(:items){primary_key :id; int4multirange :i4; int8multirange :i8; nummultirange :n; datemultirange :d; tsmultirange :t; tstzmultirange :tz}
    c = Class.new(Sequel::Model(@db[:items]))
    v = c.create(@pgr).values
    v.delete(:id)
    v.must_be :==, @pgr

    @db.create_table!(:items){primary_key :id; column :i4, 'int4multirange[]'; column :i8, 'int8multirange[]'; column :n, 'nummultirange[]'; column :d, 'datemultirange[]'; column :t, 'tsmultirange[]'; column :tz, 'tstzmultirange[]'}
    c = Class.new(Sequel::Model(@db[:items]))
    v = c.create(@pgra).values
    v.delete(:id)
    v.each{|k,v1| v1.must_be :==, @pgra[k].to_a}
  end

  it 'operations/functions with pg_range_ops' do
    Sequel.extension :pg_range_ops
    mr = lambda do |range|
      type = (Range === range ? 'int4multirange' : range.db_type.to_s.sub('range', 'multirange'))
      Sequel.pg_multirange([range], type)
    end

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(mr[2..4])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(mr[3..6])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(mr[0..6])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(Sequel.pg_range(1..5, :int4range))).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(Sequel.pg_range(3..6, :int4range))).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(Sequel.pg_range(0..6, :int4range))).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(3)).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contains(6)).must_equal false
    @db.get(Sequel.pg_range(0..6, :int4range).op.contains(mr[Sequel.pg_range(1..5, :int4range)])).must_equal true
    @db.get(Sequel.pg_range(3..6, :int4range).op.contains(mr[Sequel.pg_range(1..5, :int4range)])).must_equal false

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contained_by(mr[0..6])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contained_by(mr[3..6])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contained_by(mr[2..4])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contained_by(Sequel.pg_range(0..6, :int4range))).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.contained_by(Sequel.pg_range(3..6, :int4range))).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.contained_by(mr[Sequel.pg_range(0..6, :int4range)])).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.contained_by(mr[Sequel.pg_range(3..6, :int4range)])).must_equal false

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.overlaps(mr[5..6])).must_equal true
    @db.get(mr[Sequel.pg_range(1...5, :int4range)].op.overlaps(mr[5..6])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.overlaps(Sequel.pg_range(5..6, :int4range))).must_equal true
    @db.get(mr[Sequel.pg_range(1...5, :int4range)].op.overlaps(Sequel.pg_range(5..6, :int4range))).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.overlaps(mr[Sequel.pg_range(5..6, :int4range)])).must_equal true
    @db.get(Sequel.pg_range(1...5, :int4range).op.overlaps(mr[Sequel.pg_range(5..6, :int4range)])).must_equal false
    
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.left_of(mr[6..10])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.left_of(mr[5..10])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.left_of(mr[-1..0])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.left_of(mr[-1..3])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.left_of(Sequel.pg_range(6..10, :int4range))).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.left_of(Sequel.pg_range(5..10, :int4range))).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.left_of(mr[Sequel.pg_range(6..10, :int4range)])).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.left_of(mr[Sequel.pg_range(5..10, :int4range)])).must_equal false

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.right_of(mr[6..10])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.right_of(mr[5..10])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.right_of(mr[-1..0])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.right_of(mr[-1..3])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.right_of(Sequel.pg_range(6..10, :int4range))).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.right_of(Sequel.pg_range(-1..0, :int4range))).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.right_of(mr[Sequel.pg_range(6..10, :int4range)])).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.right_of(mr[Sequel.pg_range(-1..0, :int4range)])).must_equal true

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.ends_before(mr[6..10])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.ends_before(mr[5..10])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.ends_before(mr[-1..0])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.ends_before(mr[-1..3])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.ends_before(mr[-1..7])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.ends_before(Sequel.pg_range(5..10, :int4range))).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.ends_before(Sequel.pg_range(-1..0, :int4range))).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.ends_before(mr[Sequel.pg_range(5..10, :int4range)])).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.ends_before(mr[Sequel.pg_range(-1..0, :int4range)])).must_equal false

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(mr[6..10])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(mr[5..10])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(mr[3..10])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(mr[-1..10])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(mr[-1..0])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(mr[-1..3])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(mr[-5..-1])).must_equal true
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(Sequel.pg_range(3..10, :int4range))).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.starts_after(Sequel.pg_range(-1..10, :int4range))).must_equal true
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(mr[Sequel.pg_range(3..10, :int4range)])).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.starts_after(mr[Sequel.pg_range(-1..10, :int4range)])).must_equal true

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.adjacent_to(mr[6..10])).must_equal true
    @db.get(mr[Sequel.pg_range(1...5, :int4range)].op.adjacent_to(mr[6..10])).must_equal false
    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.adjacent_to(Sequel.pg_range(6..10, :int4range))).must_equal true
    @db.get(mr[Sequel.pg_range(1...5, :int4range)].op.adjacent_to(Sequel.pg_range(6..10, :int4range))).must_equal false
    @db.get(Sequel.pg_range(1..5, :int4range).op.adjacent_to(mr[Sequel.pg_range(6..10, :int4range)])).must_equal true
    @db.get(Sequel.pg_range(1...5, :int4range).op.adjacent_to(mr[Sequel.pg_range(6..10, :int4range)])).must_equal false

    @db.get((mr[Sequel.pg_range(1..5, :int4range)].op + (mr[6..10])).adjacent_to(mr[6..10])).must_equal false
    @db.get((mr[Sequel.pg_range(1..5, :int4range)].op + (mr[6..10])).adjacent_to(mr[11..20])).must_equal true

    @db.get((mr[Sequel.pg_range(1..5, :int4range)].op * (mr[2..6])).adjacent_to(mr[6..10])).must_equal true
    @db.get((mr[Sequel.pg_range(1..4, :int4range)].op * (mr[2..6])).adjacent_to(mr[6..10])).must_equal false

    @db.get((mr[Sequel.pg_range(1..5, :int4range)].op - (mr[2..6])).adjacent_to(mr[2..10])).must_equal true
    @db.get((mr[Sequel.pg_range(0..4, :int4range)].op - (mr[3..6])).adjacent_to(mr[4..10])).must_equal false

    @db.get(mr[Sequel.pg_range(0..4, :int4range)].op.lower).must_equal 0
    @db.get(mr[Sequel.pg_range(0..4, :int4range)].op.upper).must_equal 5

    @db.get(mr[Sequel.pg_range(0..4, :int4range)].op.isempty).must_equal false
    @db.get(mr[Sequel::Postgres::PGRange.empty(:int4range)].op.isempty).must_equal true

    @db.get(mr[Sequel.pg_range(1..5, :numrange)].op.lower_inc).must_equal true
    @db.get(mr[Sequel::Postgres::PGRange.new(1, 5, :exclude_begin=>true, :db_type=>:numrange)].op.lower_inc).must_equal false

    @db.get(mr[Sequel.pg_range(1..5, :numrange)].op.upper_inc).must_equal true
    @db.get(mr[Sequel.pg_range(1...5, :numrange)].op.upper_inc).must_equal false

    @db.get(mr[Sequel::Postgres::PGRange.new(1, 5, :db_type=>:int4range)].op.lower_inf).must_equal false
    @db.get(mr[Sequel::Postgres::PGRange.new(nil, 5, :db_type=>:int4range)].op.lower_inf).must_equal true

    @db.get(mr[Sequel::Postgres::PGRange.new(1, 5, :db_type=>:int4range)].op.upper_inf).must_equal false
    @db.get(mr[Sequel::Postgres::PGRange.new(1, nil, :db_type=>:int4range)].op.upper_inf).must_equal true

    @db.get(mr[Sequel.pg_range(1..5, :int4range)].op.range_merge.adjacent_to(mr[6..10])).must_equal true
    @db.get(Sequel.pg_range(1...5, :int4range).op.multirange.adjacent_to(mr[6..10])).must_equal false
    @db.get(Sequel.pg_range(1...5, :int4range).op.multirange.unnest).to_range.must_equal 1...5
  end
end if DB.server_version >= 140000

describe 'PostgreSQL interval types' do
  before(:all) do
    @db = DB
    @ds = @db[:items]
    m = Sequel::Postgres::IntervalDatabaseMethods::Parser
    @year = m::SECONDS_PER_YEAR
    @month = m::SECONDS_PER_MONTH
  end
  after do
    @db.drop_table?(:items)
  end

  it 'insert and retrieve interval values' do
    @db.create_table!(:items){interval :i}
    [
      ['0', '00:00:00',  0, []],
      ['1', '00:00:01',  1, [[:seconds, 1]]],
      ['1 microsecond', '00:00:00.000001',  0.000001, [[:seconds, 0.000001]]],
      ['1 millisecond', '00:00:00.001',  0.001, [[:seconds, 0.001]]],
      ['1 second', '00:00:01', 1, [[:seconds, 1]]],
      ['1 minute', '00:01:00', 60, [[:seconds, 60]]],
      ['1 hour', '01:00:00', 3600, [[:seconds, 3600]]],
      ['123000 hours', '123000:00:00', 442800000, [[:seconds, 442800000]]],
      ['1 day', '1 day', 86400, [[:days, 1]]],
      ['1 week', '7 days', 86400*7, [[:days, 7]]],
      ['1 month', '1 mon', @month, [[:months, 1]]],
      ['1 year', '1 year', @year, [[:years, 1]]],
      ['1 decade', '10 years', @year*10, [[:years, 10]]],
      ['1 century', '100 years', @year*100, [[:years, 100]]],
      ['1 millennium', '1000 years', @year*1000, [[:years, 1000]]],
      ['1 year 2 months 3 weeks 4 days 5 hours 6 minutes 7 seconds', '1 year 2 mons 25 days 05:06:07', @year + 2*@month + 3*86400*7 + 4*86400 + 5*3600 + 6*60 + 7, [[:years, 1], [:months, 2], [:days, 25], [:seconds, 18367]]],
      ['-1 year +2 months -3 weeks +4 days -5 hours +6 minutes -7 seconds', '-10 mons -17 days -04:54:07', -10*@month - 3*86400*7 + 4*86400 - 5*3600 + 6*60 - 7, [[:months, -10], [:days, -17], [:seconds, -17647]]],
      ['+2 years -1 months +3 weeks -4 days +5 hours -6 minutes +7 seconds', '1 year 11 mons 17 days 04:54:07', @year + 11*@month + 3*86400*7 - 4*86400 + 5*3600 - 6*60 + 7, [[:years, 1], [:months, 11], [:days, 17], [:seconds, 17647]]],
    ].each do |instr, outstr, value, parts|
      @ds.insert(instr)
      @ds.count.must_equal 1
      @ds.get(Sequel.cast(:i, String)).must_equal outstr
      rs = @ds.all
      rs.first[:i].is_a?(ActiveSupport::Duration).must_equal true
      rs.first[:i].must_equal ActiveSupport::Duration.new(value, parts)
      rs.first[:i].parts.sort_by{|k,v| k.to_s}.reject{|k,v| v == 0}.must_equal parts.sort_by{|k,v| k.to_s}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs
      @ds.delete
    end
  end

  it 'insert and retrieve interval array values' do
    @db.create_table!(:items){column :i, 'interval[]'}
    @ds.insert(Sequel.pg_array(['1 year 2 months 3 weeks 4 days 5 hours 6 minutes 7 seconds'], 'interval'))
    @ds.count.must_equal 1
    rs = @ds.all
    rs.first[:i].is_a?(Sequel::Postgres::PGArray).must_equal true
    rs.first[:i].first.is_a?(ActiveSupport::Duration).must_equal true
    rs.first[:i].first.must_equal ActiveSupport::Duration.new(@year + 2*@month + 3*86400*7 + 4*86400 + 5*3600 + 6*60 + 7, [[:years, 1], [:months, 2], [:days, 25], [:seconds, 18367]])
    rs.first[:i].first.parts.sort_by{|k,v| k.to_s}.must_equal [[:years, 1], [:months, 2], [:days, 25], [:seconds, 18367]].sort_by{|k,v| k.to_s}
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs
  end

  it 'use intervals in bound variables' do
    @db.create_table!(:items){interval :i}
    @ds.insert('1 year 2 months 3 weeks 4 days 5 hours 6 minutes 7 seconds')
    d = @ds.get(:i)
    @ds.delete

    @ds.call(:insert, {:i=>d}, {:i=>:$i})
    @ds.get(:i).must_equal d
    @ds.filter(:i=>:$i).call(:first, :i=>d).must_equal(:i=>d)
    @ds.filter(:i=>Sequel.cast(:$i, :interval)).call(:first, :i=>'0').must_be_nil
    @ds.filter(:i=>:$i).call(:delete, :i=>d).must_equal 1

    @db.create_table!(:items){column :i, 'interval[]'}
    @ds.call(:insert, {:i=>[d]}, {:i=>:$i})
    @ds.filter(:i=>:$i).call(:first, :i=>[d]).must_equal(:i=>[d])
    @ds.filter(:i=>:$i).call(:first, :i=>[]).must_be_nil
    @ds.filter(:i=>:$i).call(:delete, :i=>[d]).must_equal 1
  end if uses_pg_or_jdbc

  it 'parse default values for schema' do
    @db.create_table!(:items) do
      Integer :j
      interval :i, :default=>ActiveSupport::Duration.new(3*86400, :days=>3)
    end
    @db.schema(:items)[0][1][:ruby_default].must_be_nil
    @db.schema(:items)[1][1][:ruby_default].must_equal ActiveSupport::Duration.new(3*86400, :days=>3)
  end

  it 'correctly handles round tripping interval values' do
    @db.create_table!(:items) do
      interval :i
      interval :j
    end
    d = Sequel.cast(Date.new(2020, 2, 1), Date)
    {'30 days'=>Date.new(2020, 3, 2), '1 month'=>Date.new(2020, 3, 1)}.each do |interval, result|
      @ds.insert(:i=>interval)
      @ds.update(:j=>@ds.get(:i))
      @ds.where(:i=>:j).count.must_equal 1
      @ds.get{(d+:i).cast(Date).as(:v)}.must_equal result
      @ds.get{(d+:j).cast(Date).as(:v)}.must_equal result
      @ds.delete
    end
  end

  it 'with models' do
    @db.create_table!(:items) do
      primary_key :id
      interval :i
    end
    c = Class.new(Sequel::Model(@db[:items]))
    v = c.create(:i=>'1 year 2 mons 25 days 05:06:07').i
    v.is_a?(ActiveSupport::Duration).must_equal true
    v.must_equal ActiveSupport::Duration.new(@year + 2*@month + 3*86400*7 + 4*86400 + 5*3600 + 6*60 + 7, [[:years, 1], [:months, 2], [:days, 25], [:seconds, 18367]])
    v.parts.sort_by{|k,_| k.to_s}.must_equal [[:years, 1], [:months, 2], [:days, 25], [:seconds, 18367]].sort_by{|k,_| k.to_s}
  end
end if (begin require 'active_support'; require 'active_support/duration'; require 'active_support/inflector'; require 'active_support/core_ext/string/inflections'; true; rescue LoadError; false end)

describe 'PostgreSQL row-valued/composite types' do
  before(:all) do
    @db = DB
    Sequel.extension :pg_array_ops, :pg_row_ops
    @ds = @db[:person]

    @db.drop_table?(:company, :person, :address)

    @db.create_table(:address) do
      String :street
      String :city
      String :zip
    end
    @db.create_table(:person) do
      Integer :id
      address :address
    end
    @db.create_table(:company) do
      Integer :id
      column :employees, 'person[]'
    end
    oids = @db.conversion_procs.keys
    @db.register_row_type(:address)
    @db.register_row_type(Sequel.qualify(:public, :person))
    @db.register_row_type(Sequel[:public][:company])
    @new_oids = @db.conversion_procs.keys - oids
  end
  after(:all) do
    @new_oids.each{|oid| @db.conversion_procs.delete(oid)}
    @db.row_types.clear
    @db.drop_table?(:company, :person, :address)
  end
  after do
    [:company, :person, :address].each{|t| @db[t].delete}
  end

  it 'insert and retrieve row types' do
    @ds.insert(:id=>1, :address=>Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345']))
    @ds.count.must_equal 1
    # Single row valued type
    rs = @ds.all
    v = rs.first[:address]
    v.class.superclass.must_equal(Sequel::Postgres::PGRow::HashRow)
    v.to_hash.must_be_kind_of(Hash)
    v.to_hash.must_equal(:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345')
    @ds.delete
    @ds.insert(rs.first)
    @ds.all.must_equal rs

    # Nested row value type
    p = @ds.get(:person)
    p[:id].must_equal 1
    p[:address].must_equal v
  end

  it 'insert and retrieve row types containing domains' do
    begin
      @db << "DROP DOMAIN IF EXISTS positive_integer CASCADE"
      @db << "CREATE DOMAIN positive_integer AS integer CHECK (VALUE > 0)"
      @db.create_table!(:domain_check) do
        positive_integer :id
      end
      @db.register_row_type(:domain_check)
      @db.get(@db.row_type(:domain_check, [1])).must_equal(:id=>1)
      @db.register_row_type(Sequel[:public][:domain_check])
      @db.get(@db.row_type(Sequel[:public][:domain_check], [1])).must_equal(:id=>1)
      @db.get(@db.row_type(Sequel.qualify(:public, :domain_check), [1])).must_equal(:id=>1)
    ensure
      @db.drop_table(:domain_check)
      @db << "DROP DOMAIN positive_integer"
    end
  end

  it 'insert and retrieve arrays of row types' do
    @ds = @db[:company]
    @ds.insert(:id=>1, :employees=>Sequel.pg_array([@db.row_type(:person, [1, Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345'])])]))
    @ds.count.must_equal 1
    v = @ds.get(:company)
    v.class.superclass.must_equal(Sequel::Postgres::PGRow::HashRow)
    v.to_hash.must_be_kind_of(Hash)
    v[:id].must_equal 1
    employees = v[:employees]
    employees.class.must_equal(Sequel::Postgres::PGArray)
    employees.to_a.must_be_kind_of(Array)
    employees.must_equal [{:id=>1, :address=>{:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345'}}]
    @ds.delete
    @ds.insert(v[:id], v[:employees])
    @ds.get(:company).must_equal v
  end

  it 'use row types in bound variables' do
    @ds.call(:insert, {:address=>Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345'])}, {:address=>:$address, :id=>1})
    @ds.get(:address).must_equal(:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345')
    @ds.filter(:address=>Sequel.cast(:$address, :address)).call(:first, :address=>Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345']))[:id].must_equal 1
    @ds.filter(:address=>Sequel.cast(:$address, :address)).call(:first, :address=>Sequel.pg_row(['123 Sesame St', 'Somewhere', '12356'])).must_be_nil

    @ds.delete
    @ds.call(:insert, {:address=>Sequel.pg_row([nil, nil, nil])}, {:address=>:$address, :id=>1})
    @ds.get(:address).must_equal(:street=>nil, :city=>nil, :zip=>nil)
  end if uses_pg_or_jdbc

  it 'use arrays of row types in bound variables' do
    @ds = @db[:company]
    @ds.call(:insert, {:employees=>Sequel.pg_array([@db.row_type(:person, [1, Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345'])])])}, {:employees=>:$employees, :id=>1})
    @ds.get(:company).must_equal(:id=>1, :employees=>[{:id=>1, :address=>{:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345'}}])
    @ds.filter(:employees=>Sequel.cast(:$employees, 'person[]')).call(:first, :employees=>Sequel.pg_array([@db.row_type(:person, [1, Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345'])])]))[:id].must_equal 1
    @ds.filter(:employees=>Sequel.cast(:$employees, 'person[]')).call(:first, :employees=>Sequel.pg_array([@db.row_type(:person, [1, Sequel.pg_row(['123 Sesame St', 'Somewhere', '12356'])])])).must_be_nil

    @ds.delete
    @ds.call(:insert, {:employees=>Sequel.pg_array([@db.row_type(:person, [1, Sequel.pg_row([nil, nil, nil])])])}, {:employees=>:$employees, :id=>1})
    @ds.get(:employees).must_equal [{:address=>{:city=>nil, :zip=>nil, :street=>nil}, :id=>1}]
  end if uses_pg_or_jdbc

  it 'operations/functions with pg_row_ops' do
    @ds.insert(:id=>1, :address=>Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345']))
    @ds.get(Sequel.pg_row(:address)[:street]).must_equal '123 Sesame St'
    @ds.get(Sequel.pg_row(:address)[:city]).must_equal 'Somewhere'
    @ds.get(Sequel.pg_row(:address)[:zip]).must_equal '12345'

    @ds = @db[:company]
    @ds.insert(:id=>1, :employees=>Sequel.pg_array([@db.row_type(:person, [1, Sequel.pg_row(['123 Sesame St', 'Somewhere', '12345'])])]))
    @ds.get(Sequel.pg_row(:company)[:id]).must_equal 1
    @ds.get(Sequel.pg_row(:company)[:employees]).must_equal [{:id=>1, :address=>{:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345'}}]
    @ds.get(Sequel.pg_row(:company)[:employees][1]).must_equal(:id=>1, :address=>{:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345'})
    @ds.get(Sequel.pg_row(:company)[:employees][1][:address]).must_equal(:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345')
    @ds.get(Sequel.pg_row(:company)[:employees][1][:id]).must_equal 1
    @ds.get(Sequel.pg_row(:company)[:employees][1][:address][:street]).must_equal '123 Sesame St'
    @ds.get(Sequel.pg_row(:company)[:employees][1][:address][:city]).must_equal 'Somewhere'
    @ds.get(Sequel.pg_row(:company)[:employees][1][:address][:zip]).must_equal '12345'

    @db.get(@ds.get(Sequel.pg_row(:company)[:employees][1][:address]).op[:street]).must_equal '123 Sesame St'

    if DB.server_version >= 130000
      @db.get(Sequel.pg_row([1,2,3]).op[:f1]).must_equal 1
    end
  end

  describe "#splat and #*" do
    before(:all) do
      @db.create_table!(:a){Integer :a}
      @db.create_table!(:b){a :b; Integer :a}
      @db.register_row_type(:a)
      @db.register_row_type(:b)
      @db[:b].insert(:a=>1, :b=>@db.row_type(:a, [2]))
    end
    after(:all) do
      @db.drop_table?(:b, :a)
    end

    it "splat should reference the table type" do
      @db[:b].select(:a).first.must_equal(:a=>1)
      @db[:b].select(Sequel[:b][:a]).first.must_equal(:a=>1)
      @db[:b].select(Sequel.pg_row(:b)[:a]).first.must_equal(:a=>2)
      @db[:b].select(Sequel.pg_row(:b).splat[:a]).first.must_equal(:a=>1)

      @db[:b].select(:b).first.must_equal(:b=>{:a=>2})
      @db[:b].select(Sequel.pg_row(:b).splat).first.must_equal(:a=>1, :b=>{:a=>2})
      @db[:b].select(Sequel.pg_row(:b).splat(:b)).first.must_equal(:b=>{:a=>1, :b=>{:a=>2}})
    end

    it "* should expand the table type into separate columns" do
      ds = @db[:b].select(Sequel.pg_row(:b).splat(:b)).from_self(:alias=>:t)
      ds.first.must_equal(:b=>{:a=>1, :b=>{:a=>2}})
      ds.select(Sequel.pg_row(:b).*).first.must_equal(:a=>1, :b=>{:a=>2})
      ds.select(Sequel.pg_row(:b)[:b]).first.must_equal(:b=>{:a=>2})
      ds.select(Sequel.pg_row(Sequel[:t][:b]).*).first.must_equal(:a=>1, :b=>{:a=>2})
      ds.select(Sequel.pg_row(Sequel[:t][:b])[:b]).first.must_equal(:b=>{:a=>2})
      ds.select(Sequel.pg_row(:b)[:a]).first.must_equal(:a=>1)
      ds.select(Sequel.pg_row(Sequel[:t][:b])[:a]).first.must_equal(:a=>1)
    end
  end

  describe "with models" do
    before(:all) do
      class Address < Sequel::Model(:address)
        plugin :pg_row
      end
      class Person < Sequel::Model(:person)
        plugin :pg_row
      end
      class Company < Sequel::Model(:company)
        plugin :pg_row
      end
      @a = Address.new(:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345')
      @es = Sequel.pg_array([Person.new(:id=>1, :address=>@a)])
    end
    after(:all) do
      Object.send(:remove_const, :Address) rescue nil
      Object.send(:remove_const, :Person) rescue nil
      Object.send(:remove_const, :Company) rescue nil
    end

    it 'create model objects whose values are model instances using pg_row' do
      person = Person.create(:id=>1, :address=>@a)
      person.address.must_equal @a
      Person.count.must_equal 1

      company = Company.create(:employees=>[person])
      company.employees.must_equal [person]
      Company.count.must_equal 1
    end

    it 'insert and retrieve row types as model objects' do
      @ds.insert(:id=>1, :address=>@a)
      @ds.count.must_equal 1
      # Single row valued type
      rs = @ds.all
      v = rs.first[:address]
      v.must_be_kind_of(Address)
      v.must_equal @a
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.must_equal rs

      # Nested row value type
      p = @ds.get(:person)
      p.must_be_kind_of(Person)
      p.id.must_equal 1
      p.address.must_be_kind_of(Address)
      p.address.must_equal @a
    end

    it 'insert and retrieve arrays of row types as model objects' do
      @ds = @db[:company]
      @ds.insert(:id=>1, :employees=>@es)
      @ds.count.must_equal 1
      v = @ds.get(:company)
      v.must_be_kind_of(Company)
      v.id.must_equal 1
      employees = v[:employees]
      employees.class.must_equal(Sequel::Postgres::PGArray)
      employees.to_a.must_be_kind_of(Array)
      employees.must_equal @es
      @ds.delete
      @ds.insert(v.id, v.employees)
      @ds.get(:company).must_equal v
    end

    it 'use model objects in bound variables' do
      @ds.call(:insert, {:address=>@a}, {:address=>:$address, :id=>1})
      @ds.get(:address).must_equal @a
      @ds.filter(:address=>Sequel.cast(:$address, :address)).call(:first, :address=>@a)[:id].must_equal 1
      @ds.filter(:address=>Sequel.cast(:$address, :address)).call(:first, :address=>Address.new(:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12356')).must_be_nil
    end if uses_pg_or_jdbc

    it 'use arrays of model objects in bound variables' do
      @ds = @db[:company]
      @ds.call(:insert, {:employees=>@es}, {:employees=>:$employees, :id=>1})
      @ds.get(:company).must_equal Company.new(:id=>1, :employees=>@es)
      @ds.filter(:employees=>Sequel.cast(:$employees, 'person[]')).call(:first, :employees=>@es)[:id].must_equal 1
      @ds.filter(:employees=>Sequel.cast(:$employees, 'person[]')).call(:first, :employees=>Sequel.pg_array([@db.row_type(:person, [1, Sequel.pg_row(['123 Sesame St', 'Somewhere', '12356'])])])).must_be_nil
    end if uses_pg_or_jdbc

    it 'model typecasting' do
      a = Address.new(:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345')
      o = Person.create(:id=>1, :address=>['123 Sesame St', 'Somewhere', '12345'])
      o.address.must_equal a
      o = Person.create(:id=>1, :address=>{:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345'})
      o.address.must_equal a
      o = Person.create(:id=>1, :address=>a)
      o.address.must_equal a

      e = Person.new(:id=>1, :address=>a)
      o = Company.create(:id=>1, :employees=>[{:id=>1, :address=>{:street=>'123 Sesame St', :city=>'Somewhere', :zip=>'12345'}}])
      o.employees.must_equal [e]
      o = Company.create(:id=>1, :employees=>[e])
      o.employees.must_equal [e]
    end
  end
end

describe 'pg_static_cache_updater extension' do
  before(:all) do
    @db = DB
    @db.extension :pg_static_cache_updater
    @db.drop_function(@db.default_static_cache_update_name, :cascade=>true, :if_exists=>true)
    @db.create_static_cache_update_function

    @db.create_table!(:things) do
      primary_key :id
      String :name
    end
    @Thing = Class.new(Sequel::Model(:things))
    @Thing.plugin :static_cache
    @db.create_static_cache_update_trigger(:things)
  end
  after(:all) do
    @db.drop_table(:things)
    @db.drop_function(@db.default_static_cache_update_name)
  end

  it "should reload model static cache when underlying table changes" do
    @Thing.all.must_equal []
    q = Queue.new
    q1 = Queue.new

    @db.listen_for_static_cache_updates(@Thing, :timeout=>0, :loop=>proc{q.push(nil); q1.pop.call}, :before_thread_exit=>proc{q.push(nil)})

    q.pop
    q1.push(proc{@db[:things].insert(1, 'A')})
    q.pop
    @Thing.all.must_equal [@Thing.load(:id=>1, :name=>'A')]

    q1.push(proc{@db[:things].update(:name=>'B')})
    q.pop
    @Thing.all.must_equal [@Thing.load(:id=>1, :name=>'B')]

    q1.push(proc{@db[:things].delete})
    q.pop
    @Thing.all.must_equal []

    q1.push(proc{throw :stop})
    q.pop
  end
end if uses_pg && DB.server_version >= 90000

describe 'PostgreSQL enum types' do
  before do
    @db = DB
    @initial_enum_values = %w'a b c d'
    @db.create_enum(:test_enum, @initial_enum_values)

    @db.create_table!(:test_enumt) do
      test_enum  :t
    end
  end
  after do
    @db.drop_table?(:test_enumt)
    @db.drop_enum(:test_enum)
  end

  it "should return correct entries in the schema" do
    s = @db.schema(:test_enumt)
    s.first.last[:type].must_equal :enum
    s.first.last[:enum_values].must_equal @initial_enum_values
  end

  it "should add array parsers for enum values" do
    @db.get(Sequel.pg_array(%w'a b', :test_enum)).must_equal %w'a b'
  end

  it "should set up model typecasting correctly" do
    c = Class.new(Sequel::Model(:test_enumt))
    o = c.new
    o.t = :a
    o.t.must_equal 'a'
  end

  it "should add values to existing enum" do
    @db.add_enum_value(:test_enum, 'e')
    @db.add_enum_value(:test_enum, 'f', :after=>'a')
    @db.add_enum_value(:test_enum, 'g', :before=>'b')
    @db.add_enum_value(:test_enum, 'a', :if_not_exists=>true) if @db.server_version >= 90300
    @db.schema(:test_enumt, :reload=>true).first.last[:enum_values].must_equal %w'a f g b c d e'
  end if DB.server_version >= 90100

  it "should rename existing enum" do
    @db.rename_enum(:test_enum, :new_enum)
    @db.schema(:test_enumt, :reload=>true).first.last[:db_type].must_equal 'new_enum'
    @db.schema(:test_enumt, :reload=>true).first.last[:enum_values].must_equal @initial_enum_values
    @db.rename_enum(:new_enum, :test_enum)
  end

  it "should rename enum values" do
    @db.rename_enum_value(:test_enum, :b, :x)
    new_enum_values = @initial_enum_values
    new_enum_values[new_enum_values.index('b')] = 'x'
    @db.schema(:test_enumt, :reload=>true).first.last[:enum_values].must_equal new_enum_values
    @db.rename_enum_value(:test_enum, :x, :b)
  end if DB.server_version >= 100000
end

describe "PostgreSQL stored procedures for datasets" do
  before do
    @db = DB
    @db.create_table!(:items) do
      primary_key :id
      integer :numb
    end
    @db.execute(<<-SQL)
      create or replace function insert_item(numb bigint)
      returns items.id%type
      as $$
        declare
          l_id items.id%type;
        begin
          l_id := 1;

          insert into items(id, numb) values(l_id, numb);

          return l_id;
        end;
      $$ language plpgsql;
    SQL

    @ds = @db[:items]
  end

  after do
    @db.drop_function("insert_item", :if_exists=>true)
    @db.drop_table?(:items)
  end

  it "should correctly call stored procedure for inserting record" do
    result = @ds.call_sproc(:insert, :insert_item, 100)
    result.must_be_nil

    @ds.call(:all).must_equal [{:id=>1, :numb=>100}]
  end
end if DB.adapter_scheme == :jdbc

describe "pg_auto_constraint_validations plugin" do
  before(:all) do
    @db = DB
    @db.create_table!(:test1) do
      Integer :id, :primary_key=>true
      Integer :i, :unique=>true, :null=>false
      constraint :valid_i, Sequel[:i] < 10
      constraint(:valid_i_id, Sequel[:i] + Sequel[:id] < 20)
    end
    @db.run "CREATE OR REPLACE FUNCTION valid_test1(t1 test1) RETURNS boolean AS 'SELECT t1.i != -100' LANGUAGE SQL;"
    @db.alter_table(:test1) do
      add_constraint(:valid_test1, Sequel.function(:valid_test1, :test1))
    end
    @db.create_table!(:test2) do
      Integer :test2_id, :primary_key=>true
      foreign_key :test1_id, :test1
      index [:test1_id], :unique=>true, :where=>(Sequel[:test1_id] < 10)
    end
    @c1 = Sequel::Model(:test1)
    @c2 = Sequel::Model(:test2)
    @c1.plugin :update_primary_key
    @c1.plugin :pg_auto_constraint_validations
    @c2.plugin :pg_auto_constraint_validations
    @c1.unrestrict_primary_key
    @c2.unrestrict_primary_key
  end
  before do
    @c2.dataset.delete
    @c1.dataset.delete
    @c1.insert(:id=>1, :i=>2)
    @c2.insert(:test2_id=>3, :test1_id=>1)
  end
  after(:all) do
    @db.run "ALTER TABLE test1 DROP CONSTRAINT IF EXISTS valid_test1"
    @db.run "DROP FUNCTION IF EXISTS valid_test1(test1)"
    @db.drop_table?(:test2, :test1)
  end

  it "should handle check constraint failures as validation errors when creating" do
    o = @c1.new(:id=>5, :i=>12)
    proc{o.save}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['is invalid'])
  end

  it "should handle check constraint failures where the columns are unknown, if columns are explicitly specified" do
    o = @c1.new(:id=>5, :i=>-100)
    proc{o.save}.must_raise Sequel::CheckConstraintViolation
    @c1.pg_auto_constraint_validation_override(:valid_test1, :i, "should not be -100")
    proc{o.save}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['should not be -100'])
  end

  it "should handle check constraint failures as validation errors when updating" do
    o = @c1.new(:id=>5, :i=>3)
    o.save
    proc{o.update(:i=>12)}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['is invalid'])
  end

  it "should handle unique constraint failures as validation errors when creating" do
    o = @c1.new(:id=>5, :i=>2)
    proc{o.save}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['is already taken'])
  end

  it "should handle unique constraint failures as validation errors when updating" do
    o = @c1.new(:id=>5, :i=>3)
    o.save
    proc{o.update(:i=>2)}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['is already taken'])
  end

  it "should handle unique constraint failures as validation errors for partial unique indexes" do
    @c1.create(:id=>2, :i=>3)
    @c2.create(:test2_id=>6, :test1_id=>2)
    o = @c2.new(:test2_id=>5, :test1_id=>2)
    proc{o.save}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:test1_id=>['is already taken'])
  end

  it "should handle not null constraint failures as validation errors when creating" do
    o = @c1.new(:id=>5)
    proc{o.save}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['is not present'])
  end

  it "should handle not null constraint failures as validation errors when updating" do
    o = @c1.new(:id=>5, :i=>3)
    o.save
    proc{o.update(:i=>nil)}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['is not present'])
  end

  it "should handle foreign key constraint failures as validation errors when creating" do
    o = @c2.new(:test2_id=>4, :test1_id=>2)
    proc{o.save}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:test1_id=>['is invalid'])
  end

  it "should handle foreign key constraint failures as validation errors when updating" do
    o = @c2.first
    proc{o.update(:test1_id=>2)}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:test1_id=>['is invalid'])
  end

  it "should handle foreign key constraint failures in other tables as validation errors when updating" do
    o = @c1[1]
    proc{o.update(:id=>2)}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:id=>['cannot be changed currently'])
  end

  it "should handle multi-column constraint failures as validation errors" do
    c = Class.new(@c1)
    o = c.new(:id=>18, :i=>8)
    proc{o.save}.must_raise Sequel::ValidationFailed
    [{[:i, :id]=>['is invalid']}, {[:id, :i]=>['is invalid']}].must_include o.errors
  end

  it "should handle multi-column constraint failures as validation errors when using the error_splitter plugin" do
    c = Class.new(@c1)
    c.plugin :error_splitter
    o = c.new(:id=>18, :i=>8)
    proc{o.save}.must_raise Sequel::ValidationFailed
    o.errors.must_equal(:i=>['is invalid'], :id=>['is invalid'])
  end

  it "should handle dumping cached metadata and loading metadata from cache" do
    cache_file = "spec/files/pgacv-#{$$}.cache"
    begin
      c = Class.new(Sequel::Model)
      c.plugin :pg_auto_constraint_validations, :cache_file=>cache_file
      c1 = Class.new(c)
      def c1.name; 'Foo' end
      c1.dataset = DB[:test1]
      c2 = Class.new(c)
      def c2.name; 'Bar' end
      c2.dataset = DB[:test2]
      c1.unrestrict_primary_key
      c2.unrestrict_primary_key

      o = c1.new(:id=>5, :i=>12)
      proc{o.save}.must_raise Sequel::ValidationFailed
      o.errors.must_equal(:i=>['is invalid'])
      o = c2.new(:test2_id=>4, :test1_id=>2)
      proc{o.save}.must_raise Sequel::ValidationFailed
      o.errors.must_equal(:test1_id=>['is invalid'])

      c.dump_pg_auto_constraint_validations_cache

      c = Class.new(Sequel::Model)
      c.plugin :pg_auto_constraint_validations, :cache_file=>cache_file
      c1 = Class.new(c)
      def c1.name; 'Foo' end
      c1.dataset = DB[:test1]
      c2 = Class.new(c)
      def c2.name; 'Bar' end
      c2.dataset = DB[:test2]
      c1.unrestrict_primary_key
      c2.unrestrict_primary_key

      o = c1.new(:id=>5, :i=>12)
      proc{o.save}.must_raise Sequel::ValidationFailed
      o.errors.must_equal(:i=>['is invalid'])
      o = c2.new(:test2_id=>4, :test1_id=>2)
      proc{o.save}.must_raise Sequel::ValidationFailed
      o.errors.must_equal(:test1_id=>['is invalid'])
    ensure
      File.delete(cache_file) if File.file?(cache_file)
    end
  end
end if DB.respond_to?(:error_info) && DB.server_version >= 90300

describe "Common Table Expression SEARCH" do
  before(:all) do
    @db = DB
    @db.create_table!(:i1){Integer :id; Integer :parent_id}
    @ds = @db[:i1]
    @ds.insert(:id=>1)
    @ds.insert(:id=>2)
    @ds.insert(:id=>3, :parent_id=>1)
    @ds.insert(:id=>4, :parent_id=>1)
    @ds.insert(:id=>5, :parent_id=>3)
    @ds.insert(:id=>6, :parent_id=>5)
  end
  after(:all) do
    @db.drop_table?(:i1)
  end
  
  it "should support :search option for depth/breadth first ordering" do
    @db[:t].with_recursive(:t, @ds.filter(:parent_id=>nil), @ds.join(:t, :id=>:parent_id).select_all(:i1), :search=>{:by=>:id}).
      order(:ordercol, :id).
      select_map([:id, :ordercol]).must_equal [
        [1, [["1"]]],
        [3, [["1"], ["3"]]],
        [5, [["1"], ["3"], ["5"]]],
        [6, [["1"], ["3"], ["5"], ["6"]]],
        [4, [["1"], ["4"]]],
        [2, [["2"]]]
      ]

    @db[:t].with_recursive(:t, @ds.filter(:parent_id=>nil), @ds.join(:t, :id=>:parent_id).select_all(:i1), :search=>{:type=>:breadth, :by=>[:id, :parent_id], :set=>:c}, :args=>[:id, :parent_id]).
      order(:c, :id).
      select_map([:id, :c]).must_equal [
        [1, ["0", "1", nil]],
        [2, ["0", "2", nil]],
        [3, ["1", "3", "1"]],
        [4, ["1", "4", "1"]],
        [5, ["2", "5", "3"]],
        [6, ["3", "6", "5"]]
      ]
  end
end if DB.server_version >= 140000

describe "Common Table Expression CYCLE" do
  before(:all) do
    @db = DB
    @db.create_table!(:i1){Integer :id; Integer :parent_id}
    @ds = @db[:i1]
    @ds.insert(:id=>1, :parent_id=>6)
    @ds.insert(:id=>2)
    @ds.insert(:id=>3, :parent_id=>1)
    @ds.insert(:id=>4, :parent_id=>1)
    @ds.insert(:id=>5, :parent_id=>3)
    @ds.insert(:id=>6, :parent_id=>5)
  end
  after(:all) do
    @db.drop_table?(:i1)
  end
  
  it "should support :cycle option for detecting cycles" do
    @db[:t].with_recursive(:t, @ds.filter(:id=>[1,2]), @ds.join(:t, :id=>:parent_id).select_all(:i1), :cycle=>{:columns=>:id}, :args=>[:id, :parent_id]).
      order(:id).
      exclude(:is_cycle).
      select_map([:id, :is_cycle, :path]).must_equal [
        [1, false, [["1"]]],
        [2, false, [["2"]]],
        [3, false, [["1"], ["3"]]],
        [4, false, [["1"], ["4"]]],
        [5, false, [["1"], ["3"], ["5"]]],
        [6, false, [["1"], ["3"], ["5"], ["6"]]]
      ]

    @db[:t].with_recursive(:t, @ds.filter(:id=>[1,2]), @ds.join(:t, :id=>:parent_id).select_all(:i1), :cycle=>{:columns=>[:id, :parent_id], :path_column=>:pc, :cycle_column=>:cc, :cycle_value=>1, :noncycle_value=>0}).
      order(:id).
      where(:cc=>0).
      select_map([:id, :cc, :pc]).must_equal [
        [1, 0, [["1", "6"]]],
        [2, 0, [["2", nil]]],
        [3, 0, [["1", "6"], ["3", "1"]]],
        [4, 0, [["1", "6"], ["4", "1"]]],
        [5, 0, [["1", "6"], ["3", "1"], ["5", "3"]]],
        [6, 0, [["1", "6"], ["3", "1"], ["5", "3"], ["6", "5"]]]
      ]
  end

  it "should support both :search and :cycle options together" do
    @db[:t].with_recursive(:t, @ds.filter(:id=>[1,2]), @ds.join(:t, :id=>:parent_id).select_all(:i1), :cycle=>{:columns=>:id}, :search=>{:by=>:id}, :args=>[:id, :parent_id]).
      order(:ordercol, :id).
      exclude(:is_cycle).
      select_map([:id, :is_cycle, :path, :ordercol]).must_equal [
        [1, false, [["1"]], [["1"]]],
        [3, false, [["1"], ["3"]], [["1"], ["3"]]],
        [5, false, [["1"], ["3"], ["5"]], [["1"], ["3"], ["5"]]],
        [6, false, [["1"], ["3"], ["5"], ["6"]], [["1"], ["3"], ["5"], ["6"]]],
        [4, false, [["1"], ["4"]], [["1"], ["4"]]],
        [2, false, [["2"]], [["2"]]]
      ]

    @db[:t].with_recursive(:t, @ds.filter(:id=>[1,2]), @ds.join(:t, :id=>:parent_id).select_all(:i1), :cycle=>{:columns=>:id}, :search=>{:type=>:breadth, :by=>:id}, :args=>[:id, :parent_id]).
      order(:ordercol, :id).
      exclude(:is_cycle).
      select_map([:id, :is_cycle, :path, :ordercol]).must_equal [
        [1, false, [["1"]], ["0", "1"]],
        [2, false, [["2"]], ["0", "2"]],
        [3, false, [["1"], ["3"]], ["1", "3"]],
        [4, false, [["1"], ["4"]], ["1", "4"]],
        [5, false, [["1"], ["3"], ["5"]], ["2", "5"]],
        [6, false, [["1"], ["3"], ["5"], ["6"]], ["3", "6"]]
      ]
  end
end if DB.server_version >= 140000

describe "MERGE DO NOTHING" do
  before(:all) do
    @db = DB
    @db.create_table!(:m1){Integer :i1; Integer :a}
    @db.create_table!(:m2){Integer :i2; Integer :b}
    @m1 = @db[:m1]
    @m2 = @db[:m2]
  end
  after do
    @m1.delete
    @m2.delete
  end
  after(:all) do
    @db.drop_table?(:m1, :m2)
  end

  it "should allow inserts, updates, do nothings, and deletes based on conditions in a single MERGE statement" do
    ds = @m1.
      merge_using(:m2, :i1=>:i2).
      merge_do_nothing_when_not_matched{b > 50}.
      merge_insert(:i1=>Sequel[:i2], :a=>Sequel[:b]+11).
      merge_do_nothing_when_matched{a > 50}.
      merge_delete{a > 30}.
      merge_update(:i1=>Sequel[:i1]+:i2+10, :a=>Sequel[:a]+:b+20)

    @m2.insert(1, 2)
    @m1.all.must_equal []

    # INSERT
    ds.merge
    @m1.all.must_equal [{:i1=>1, :a=>13}]

    # UPDATE
    ds.merge
    @m1.all.must_equal [{:i1=>12, :a=>35}]

    # DELETE MATCHING current row, INSERT NOT MATCHED new row
    @m2.insert(12, 3)
    ds.merge
    @m1.all.must_equal [{:i1=>1, :a=>13}]

    # MATCHED DO NOTHING
    @m2.where(:i2=>12).delete
    @m1.update(:a=>51)
    ds.merge
    @m1.all.must_equal [{:i1=>1, :a=>51}]

    # NOT MATCHED DO NOTHING
    @m1.delete
    @m2.update(:b=>51)
    ds.merge
    @m1.all.must_equal []

    @m2.insert(1, 2)
    @m2.insert(11, 22)
    ds = @m1.
      merge_using(:m2, :i1=>:i2).
      merge_insert(:i2, :b){b <= 10}.
      merge_update(:a=>Sequel[:a]+1){false}.
      merge_delete{false}

    ds.merge
    @m1.all.must_equal [{:i1=>1, :a=>2}]

    ds.merge
    @m1.all.must_equal [{:i1=>1, :a=>2}]
  end

  it "should consider condition blocks that return nil as NULL" do
    @m2.insert(1, 2)
    @m1.
      merge_using(:m2, :i1=>:i2).
      merge_insert(Sequel[:i2], Sequel[:b]+11){nil}.
      merge
    @m1.all.must_equal []
  end

  it "supports static SQL" do
    @m2.insert(1, 2)
    @m1.with_sql(<<SQL).merge
MERGE INTO m1 USING m2 ON (i1 = i2)
WHEN NOT MATCHED AND (b > 50) THEN DO NOTHING
WHEN NOT MATCHED THEN INSERT (i1, a) VALUES (i2, (b + 11))
WHEN MATCHED AND (a > 50) THEN DO NOTHING
WHEN MATCHED AND (a > 30) THEN DELETE
WHEN MATCHED THEN UPDATE SET i1 = (i1 + i2 + 10), a = (a + b + 20)
SQL
    @m1.all.must_equal [{:i1=>1, :a=>13}]
  end

  it "should support merge_do_nothing_* without blocks" do
    @m2.insert(1, 2)
    ds = @m1.
      merge_using(:m2, :i1=>:i2).
      merge_do_nothing_when_matched.
      merge_do_nothing_when_not_matched
    ds.merge
    @m1.all.must_equal []

    @m1.insert(1, 3)
    ds.merge
    @m1.all.must_equal [{:i1=>1, :a=>3}]
  end
end if DB.server_version >= 150000

describe "pg_xmin_optimistic_locking plugin" do
  before do
    @db = DB
    @db.create_table! :items do
      primary_key :id
      String :name, :size => 20
    end
   end
  after do
    @db.drop_table?(:items)
  end

  it "should not allow stale updates" do
    c = Class.new(Sequel::Model(:items))
    c.plugin :pg_xmin_optimistic_locking
    o = c.create(:name=>'test')
    o2 = c.first
    xmin = c.dataset.naked.get(:xmin)
    xmin.wont_equal nil
    xmin.must_equal o.xmin
    xmin.must_equal o2.xmin
    o.name = 'test2'
    o.save
    xmin.wont_equal o.xmin
    xmin.wont_equal c.dataset.naked.get(:xmin)
    proc{o2.save}.must_raise(Sequel::NoExistingObject)
  end

  it "should work with subclasses" do
    c = Class.new(Sequel::Model)
    c.plugin :pg_xmin_optimistic_locking
    sc = c::Model(:items)
    o = sc.create(:name=>'test')
    o2 = sc.first
    xmin = sc.dataset.naked.get(:xmin)
    xmin.wont_equal nil
    xmin.must_equal o.xmin
    xmin.must_equal o2.xmin
    o.name = 'test2'
    o.save
    xmin.wont_equal o.xmin
    xmin.wont_equal sc.dataset.naked.get(:xmin)
    proc{o2.save}.must_raise(Sequel::NoExistingObject)
  end

  it "should allow updates when xmin is not selected" do
    c = Class.new(Sequel::Model(:items))
    c.plugin :pg_xmin_optimistic_locking
    c.create(:name=>'test')
    o = c.select_all(:items).first
    o2 = c.first
    o.xmin.must_be_nil
    o.name = 'test2'
    o.save
    o.xmin.wont_be_nil
    o.xmin.must_equal c.dataset.naked.get(:xmin)
    proc{o2.save}.must_raise(Sequel::NoExistingObject)
  end

  it "should not select xmin when selecting from subquery" do
    c = Class.new(Sequel::Model(@db[:items].from_self))
    c.plugin :pg_xmin_optimistic_locking
    @db[:items].insert(:name=>'test')
    c.first.values[:xmin].must_be_nil
  end

  it "should not select xmin when selecting from view" do
    begin
      @db.create_view(:items_view, @db[:items])
      c = Class.new(Sequel::Model(:items_view))
      c.plugin :pg_xmin_optimistic_locking
      @db[:items].insert(:name=>'test')
      c.first.values[:xmin].must_be_nil
    ensure
      @db.drop_view(:items_view)
    end
  end
end


describe "MERGE RETURNING" do
  before(:all) do
    @db = DB
    @db.create_table!(:m1){Integer :i1; Integer :a}
    @db.create_table!(:m2){Integer :i2; Integer :b}
    @m1 = @db[:m1].returning
    @m2 = @db[:m2]
  end
  after do
    @m1.delete
    @m2.delete
  end
  after(:all) do
    @db.drop_table?(:m1, :m2)
  end

  def merge(ds)
    a = []
    ds.merge{|h| a << h}
    a
  end

  def check(ds)
    @m2.insert(1, 2)

    @m1.all.must_equal []

    # INSERT
    merge(ds).must_equal [{:i2=>1, :b=>2, :i1=>1, :a=>13}]
    @m1.all.must_equal [{:i1=>1, :a=>13}]

    # UPDATE
    merge(ds).must_equal [{:i2=>1, :b=>2, :i1=>12, :a=>35}]
    @m1.all.must_equal [{:i1=>12, :a=>35}]

    # UPDATE with specific RETURNING columns
    @m1.update(:i1=>1, :a=>13)
    merge(ds.returning(:b)).must_equal [{:b=>2}]
    @m1.all.must_equal [{:i1=>12, :a=>35}]

    # DELETE MATCHING current row, INSERT NOT MATCHED new row
    @m2.insert(12, 3)
    merge(ds).must_equal [{:i2=>1, :b=>2, :i1=>1, :a=>13}, {:i2=>12, :b=>3, :i1=>12, :a=>35}]
    @m1.all.must_equal [{:i1=>1, :a=>13}]

    # MATCHED DO NOTHING
    @m2.where(:i2=>12).delete
    @m1.update(:a=>51)
    merge(ds).must_equal []
    @m1.all.must_equal [{:i1=>1, :a=>51}]

    # NOT MATCHED DO NOTHING
    @m1.delete
    @m2.update(:b=>51)
    merge(ds).must_equal []
    @m1.all.must_equal []
  end
  
  it "should allow inserts, updates, and deletes based on conditions in a single MERGE statement" do
    ds = @m1.
      merge_using(:m2, :i1=>:i2).
      merge_insert(:i1=>Sequel[:i2], :a=>Sequel[:b]+11){b <= 50}.
      merge_delete{{:a => 30..50}}.
      merge_update(:i1=>Sequel[:i1]+:i2+10, :a=>Sequel[:a]+:b+20){a <= 50}
    check(ds)
  end

  it "should support WITH clauses" do
    ds = @m1.
      with(:m3, @db[:m2]).
      merge_using(:m3, :i1=>:i2).
      merge_insert(:i1=>Sequel[:i2], :a=>Sequel[:b]+11){b <= 50}.
      merge_delete{{:a => 30..50}}.
      merge_update(:i1=>Sequel[:i1]+:i2+10, :a=>Sequel[:a]+:b+20){a <= 50}
    check(ds)
  end if DB.dataset.supports_cte?

  it "should support inserts with just columns" do
    ds = @m1.
      merge_using(:m2, :i1=>:i2).
      merge_insert(Sequel[:i2], Sequel[:b]+11){b <= 50}.
      merge_delete{{:a => 30..50}}.
      merge_update(:i1=>Sequel[:i1]+:i2+10, :a=>Sequel[:a]+:b+20){a <= 50}
    check(ds)
  end

  it "should calls inserts, updates, and deletes without conditions" do
    @m2.insert(1, 2)
    ds = @m1.merge_using(:m2, :i1=>:i2)
    
    merge(ds.merge_insert(:i2, :b)).must_equal [{:i2=>1, :b=>2, :i1=>1, :a=>2}]
    @m1.all.must_equal [{:i1=>1, :a=>2}]

    merge(ds.merge_update(:a=>Sequel[:a]+1)).must_equal [{:i2=>1, :b=>2, :i1=>1, :a=>3}]
    @m1.all.must_equal [{:i1=>1, :a=>3}]

    merge(ds.merge_delete).must_equal [{:i2=>1, :b=>2, :i1=>1, :a=>3}]
    @m1.all.must_equal []
  end
end if DB.server_version >= 170000

describe "MERGE WHEN NOT MATCHED BY SOURCE" do
  before(:all) do
    @db = DB
    @db.create_table!(:m1){Integer :i1; Integer :a}
    @db.create_table!(:m2){Integer :i2}
    @m1 = @db[:m1]
  end
  after do
    @m1.delete
  end
  after(:all) do
    @db.drop_table?(:m1, :m2)
  end

  it "should allow inserts, updates, do nothings, and deletes based on conditions in a single MERGE statement" do
    ds = @m1.merge_using(:m2, :i1=>:i2)

    @m1.insert(1, 2)
    @m1.all.must_equal [{:i1=>1, :a=>2}]

    ds.merge_do_nothing_when_not_matched_by_source.merge
    @m1.all.must_equal [{:i1=>1, :a=>2}]

    ds.merge_update_when_not_matched_by_source(:i1=>Sequel[:i1]+10, :a=>Sequel[:a]+20).merge
    @m1.all.must_equal [{:i1=>11, :a=>22}]

    ds.merge_delete_when_not_matched_by_source.merge
    @m1.all.must_equal []

    @m1.insert(1, 100)
    @m1.insert(2, 40)
    @m1.insert(3, 20)
    @m1.insert(4, 5)

    # conditions
    ds.
      merge_do_nothing_when_not_matched_by_source{a > 50}.
      merge_delete_when_not_matched_by_source{a > 30}.
      merge_update_when_not_matched_by_source(:a=>Sequel[:a]+20){a > 10}.
      merge_update_when_not_matched_by_source(:a=>Sequel[:a]-20).
      merge
    @m1.order(:i1).all.must_equal [{:i1=>1, :a=>100}, {:i1=>3, :a=>40}, {:i1=>4, :a=>-15}]
  end
end if DB.server_version >= 170000

describe 'pg_schema_caching_extension' do
  before do
    @db = DB
    @cache_file = "spec/files/pg_schema_caching-spec-#{$$}.cache"
  end
  after do
    @db.drop_table?(:test_pg_schema_caching, :test_pg_schema_caching_type)
    File.delete(@cache_file) if File.file?(@cache_file)
  end

  it "should encode custom type OIDs as :custom, and reload them" do
    @db.create_table(:test_pg_schema_caching_type) do
      Integer :id
      String :name
    end
    @db.create_table(:test_pg_schema_caching) do
      test_pg_schema_caching_type :t
    end

    oid = @db.schema(:test_pg_schema_caching)[0][1][:oid]
    oid.must_be_kind_of Integer

    @db.extension :pg_schema_caching
    @db.dump_schema_cache(@cache_file)

    @db.instance_variable_get(:@schemas).delete('"test_pg_schema_caching"')
    cache = Marshal.load(File.binread(@cache_file))
    cache['"test_pg_schema_caching"'][0][1][:oid].must_equal :custom

    @db.load_schema_cache(@cache_file)
    @db.schema(:test_pg_schema_caching)[0][1][:oid].must_equal oid
  end
end

describe "pg_eager_any_typed_array plugin" do
  before(:all) do
    @db = DB
    @db.create_table!(:pg_eager_any_typed_array_test) do
      uuid :id, :primary_key=>true
      uuid :parent_id
      column :parent_ids, "uuid[]"
    end
    @c = Class.new(Sequel::Model(@db[:pg_eager_any_typed_array_test])) do
      plugin :pg_eager_any_typed_array
      plugin :many_through_many
      plugin :pg_array_associations
      unrestrict_primary_key

      many_to_one :parent, :class=>self
      one_to_many :children, :class=>self, :key=>:parent_id
      one_to_one :first_child, :class=>self, :key=>:parent_id
      many_to_many :grandchildren, :class=>self, :join_table=>Sequel.as(:pg_eager_any_typed_array_test, :jt), :left_key=>:parent_id, :right_key=>:id, :right_primary_key=>:parent_id
      one_through_one :first_grandchild, :class=>self, :join_table=>Sequel.as(:pg_eager_any_typed_array_test, :jt), :left_key=>:parent_id, :right_key=>:id, :right_primary_key=>:parent_id
      many_through_many :great_grandchildren, [[:pg_eager_any_typed_array_test, :parent_id, :id]]*2, :class=>self, :right_primary_key=>:parent_id
      one_through_many :first_great_grandchild, [[:pg_eager_any_typed_array_test, :parent_id, :id]]*2, :class=>self, :right_primary_key=>:parent_id
      pg_array_to_many :parents, :class=>self
      many_to_pg_array :array_children, :class=>self, :key=>:parent_ids
    end
    ids = Array.new(4){|i| "********-****-****-****-************".gsub(/\*/, i.to_s)}
    @c1 = @c.create(id: ids[0], parent_id: ids[1], parent_ids: Sequel.pg_array([ids[2], ids[3]], :uuid))
    @c2 = @c.create(id: ids[1], parent_id: ids[2])
    @c3 = @c.create(id: ids[2], parent_id: ids[3])
    @c4 = @c.create(id: ids[3])
  end
  after(:all) do
    @db.drop_table?(:pg_eager_any_typed_array_test)
  end

  def check(assoc, recv, res)
    cs = @c.where(:id=>recv.id).eager(assoc).all
    cs.must_equal [recv]
    cs[0].associations[assoc].must_equal res
  end

  it "should have correct eager loading of many_to_one association" do
    check(:parent, @c1, @c2)
  end

  it "should have correct eager loading of one_to_many association" do
    check(:children, @c2, [@c1])
  end

  it "should have correct eager loading of one_to_one association" do
    check(:first_child, @c2, @c1)
  end

  it "should have correct eager loading of many_to_many association" do
    check(:grandchildren, @c3, [@c1])
  end

  it "should have correct eager loading of one_through_one association" do
    check(:first_grandchild, @c3, @c1)
  end

  it "should have correct eager loading of many_through_many association" do
    check(:great_grandchildren, @c4, [@c1])
  end

  it "should have correct eager loading of one_through_many association" do
    check(:first_great_grandchild, @c4, @c1)
  end

  it "should have correct eager loading of pg_array_to_many association" do
    cs = @c.where(:id=>@c1.id).eager(:parents).all
    cs.must_equal [@c1]
    cs[0].associations[:parents].sort_by(&:id).must_equal [@c3, @c4]
  end

  it "should have correct eager loading of many_to_pg_array association" do
    check(:array_children, @c3, [@c1])
  end
end
