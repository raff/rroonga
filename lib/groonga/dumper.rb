# -*- coding: utf-8 -*-
#
# Copyright (C) 2011-2012  Kouhei Sutou <kou@clear-code.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License version 2.1 as published by the Free Software Foundation.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

require 'stringio'

module Groonga
  module Dumper
    module_function
    def default_output
      StringIO.new(utf8_string)
    end

    def utf8_string
      ""
    end
  end

  # データベースの内容をgrn式形式の文字列として出力するクラス。
  class DatabaseDumper
    def initialize(options={})
      @options = options
    end

    def dump
      options = @options.dup
      have_output = !@options[:output].nil?
      options[:output] ||= Dumper.default_output
      options[:error_output] ||= Dumper.default_output
      if options[:database].nil?
        options[:context] ||= Groonga::Context.default
        options[:database] = options[:context].database
      end
      options[:dump_plugins] = true if options[:dump_plugins].nil?
      options[:dump_schema] = true if options[:dump_schema].nil?
      options[:dump_tables] = true if options[:dump_tables].nil?

      if options[:dump_schema]
        schema_dumper = SchemaDumper.new(options.merge(:syntax => :command))
      end
      dump_plugins(options) if options[:dump_plugins]
      if options[:dump_schema]
        schema_dumper.dump_tables
        options[:output].write("\n")
        schema_dumper.dump_reference_columns
      end
      dump_tables(options) if options[:dump_tables]
      if options[:dump_schema]
        options[:output].write("\n")
        schema_dumper.dump_index_columns
      end

      if have_output
        nil
      else
        options[:output].string
      end
    end

    private
    def dump_plugins(options)
      plugin_paths = {}
      options[:database].each(each_options(:order_by => :id)) do |object|
        next unless object.is_a?(Groonga::Procedure)
        next if object.builtin?
        path = object.path
        next if path.nil?
        next if plugin_paths.has_key?(path)
        plugin_paths[path] = true
        dump_plugin(object, options)
      end
      options[:output].write("\n") unless plugin_paths.empty?
    end

    def dump_tables(options)
      first_table = true
      options[:database].each(each_options(:order_by => :key)) do |object|
        next unless object.is_a?(Groonga::Table)
        next if object.size.zero?
        next if target_table?(options[:exclude_tables], object, false)
        next unless target_table?(options[:tables], object, true)
        options[:output].write("\n") if !first_table or options[:dump_schema]
        first_table = false
        dump_records(object, options)
      end
    end

    def dump_records(table, options)
      TableDumper.new(table, options).dump
    end

    def dump_plugin(plugin, options)
      output = options[:output]
      plugins_dir_re = Regexp.escape(Groonga::Plugin.system_plugins_dir)
      suffix_re = Regexp.escape(Groonga::Plugin.suffix)
      plugin_name = plugin.path.gsub(/(?:\A#{plugins_dir_re}\/|
                                         #{suffix_re}\z)/x,
                                     '')
      output.write("register #{plugin_name}\n")
    end

    def target_table?(target_tables, table, default_value)
      return default_value if target_tables.nil? or target_tables.empty?
      target_tables.any? do |name|
        name === table.name
      end
    end

    def each_options(options)
      {:ignore_missing_object => true}.merge(options)
    end
  end

  # スキーマの内容をRubyスクリプトまたはgrn式形式の文字列と
  # して出力するクラス。
  class SchemaDumper
    def initialize(options={})
      @options = (options || {}).dup
    end

    def dump
      run do |syntax|
        syntax.dump
      end
    end

    def dump_tables
      run do |syntax|
        syntax.dump_tables
      end
    end

    def dump_reference_columns
      run do |syntax|
        syntax.dump_reference_columns
      end
    end

    def dump_index_columns
      run do |syntax|
        syntax.dump_index_columns
      end
    end

    private
    def create_syntax(database, output)
      case @options[:syntax]
      when :command
        CommandSyntax.new(database, output)
      else
        RubySyntax.new(database, output)
      end
    end

    def run
      database = @options[:database]
      if database.nil?
        context = @options[:context] || Groonga::Context.default
        database = context.database
      end
      return nil if database.nil?

      output = @options[:output]
      have_output = !output.nil?
      output ||= Dumper.default_output
      result = yield(create_syntax(database, output))
      if have_output
        result
      else
        output.string
      end
    end

    # @private
    class BaseSyntax
      def initialize(database, output)
        @database = database
        @output = output
        @table_defined = false
      end

      def dump
        header
        dump_schema
        footer
      end

      def dump_schema
        dump_tables
        dump_reference_columns
        dump_index_columns
      end

      def dump_tables
        each_table do |table|
          create_table(table)
        end
      end

      def dump_reference_columns
        group_columns(reference_columns).each do |table, columns|
          change_table(table) do
            columns.each do |column|
              define_reference_column(table, column)
            end
          end
        end
      end

      def dump_index_columns
        group_columns(index_columns).each do |table, columns|
          change_table(table) do
            columns.each do |column|
              define_index_column(table, column)
            end
          end
        end
      end

      private
      def write(content)
        @output.write(content)
      end

      def header
        write("")
      end

      def footer
        write("")
      end

      def each_table
        each_options = {:order_by => :key, :ignore_missing_object => true}
        @database.each(each_options) do |object|
          yield(object) if object.is_a?(Groonga::Table)
        end
      end

      def each_column(table, &block)
        sorted_columns = table.columns.sort_by {|column| column.local_name}
        sorted_columns.each(&block)
      end

      def collect_columns
        columns = []
        each_table do |table|
          each_column(table) do |column|
            columns << column if yield(column)
          end
        end
        columns
      end

      def reference_columns
        @reference_columns ||= collect_columns do |column|
          reference_column?(column)
        end
      end

      def index_columns
        @index_columns ||= collect_columns do |column|
          index_column?(column)
        end
      end

      def group_columns(columns)
        grouped_columns = columns.group_by do |column|
          column.table
        end
        sort_grouped_columns(grouped_columns)
      end

      def sort_grouped_columns(grouped_columns)
        grouped_columns = grouped_columns.collect do |table, columns|
          sorted_columns = columns.sort_by do |column|
            column.local_name
          end
          [table, sorted_columns]
        end
        grouped_columns.sort_by do |table, columns|
          _ = columns
          table.name
        end
      end

      def table_separator
        write("\n")
      end

      def column_type(column)
        if column.is_a?(Groonga::IndexColumn)
          :index
        elsif column.range.is_a?(Groonga::Table)
          :reference
        else
          :normal
        end
      end

      def index_column?(column)
        column_type(column) == :index
      end

      def reference_column?(column)
        column_type(column) == :reference
      end

      def normal_column?(column)
        column_type(column) == :normal
      end

      def create_table(table)
        table_separator if @table_defined
        create_table_header(table)
        each_column(table) do |column|
          define_column(table, column) if normal_column?(column)
        end
        create_table_footer(table)
        @table_defined = true
      end

      def change_table(table)
        table_separator if @table_defined
        change_table_header(table)
        yield(table)
        change_table_footer(table)
        @table_defined = true
      end
    end

    # @private
    class RubySyntax < BaseSyntax
      private
      def create_table_header(table)
        parameters = []
        unless table.is_a?(Groonga::Array)
          case table
          when Groonga::Hash
            parameters << ":type => :hash"
          when Groonga::PatriciaTrie
            parameters << ":type => :patricia_trie"
          end
          if table.domain
            parameters << ":key_type => #{table.domain.name.dump}"
            if table.normalize_key?
              parameters << ":key_normalize => true"
            end
          end
          default_tokenizer = table.default_tokenizer
          if default_tokenizer
            parameters << ":default_tokenizer => #{default_tokenizer.name.dump}"
          end
        end
        parameters << ":force => true"
        parameters.unshift("")
        parameters = parameters.join(",\n             ")
        write("create_table(#{table.name.dump}#{parameters}) do |table|\n")
      end

      def create_table_footer(table)
        write("end\n")
      end

      def change_table_header(table)
        write("change_table(#{table.name.inspect}) do |table|\n")
      end

      def change_table_footer(table)
        write("end\n")
      end

      def define_column(table, column)
        type = column_method(column)
        name = column.local_name
        options = column_options(column)
        arguments = [dump_object(name), options].compact.join(", ")
        write("  table.#{type}(#{arguments})\n")
      end

      def define_reference_column(table, column)
        name = column.local_name
        reference = column.range
        options = column_options(column)
        arguments = [dump_object(name),
                     dump_object(reference.name),
                     options].compact.join(", ")
        write("  table.reference(#{arguments})\n")
      end

      def define_index_column(table, column)
        target_table_name = column.range.name
        sources = column.sources
        source_names = sources.collect do |source|
          if source.is_a?(Groonga::Table)
            name = "_key"
          else
            name = source.local_name
          end
          dump_object(name)
        end.join(", ")
        arguments = [dump_object(target_table_name),
                     sources.size == 1 ? source_names : "[#{source_names}]",
                     ":name => #{dump_object(column.local_name)}"]
        write("  table.index(#{arguments.join(', ')})\n")
      end

      def column_method(column)
        range = column.range
        case range.name
        when "Bool"
          "boolean"
        when /\AInt(8|16|32|64)\z/
          "integer#{$1}"
        when /\AUInt(8|16|32|64)\z/
          "unsigned_integer#{$1}"
        when "Float"
          "float"
        when "Time"
          "time"
        when "ShortText"
          "short_text"
        when "Text"
          "text"
        when "LongText"
          "long_text"
        when "TokyoGeoPoint"
          "tokyo_geo_point"
        when "WGS84GeoPoint"
          "wgs84_geo_point"
        else
          raise ArgumentError, "unsupported column: #{column.inspect}"
        end
      end

      def column_options(column)
        options = {}
        options[:type] = :vector if column.vector?
        return nil if options.empty?

        dumped_options = ""
        options.each do |key, value|
          dumped_key = dump_object(key)
          dumped_value = dump_object(value)
          dumped_options << "#{dumped_key} => #{dumped_value}"
        end
        dumped_options
      end

      def dump_object(object)
        if object.respond_to?(:dump)
          object.dump
        else
          object.inspect
        end
      end
    end

    # @private
    class CommandSyntax < BaseSyntax
      private
      def create_table_header(table)
        parameters = []
        flags = []
        case table
        when Groonga::Array
          flags << "TABLE_NO_KEY"
        when Groonga::Hash
          flags << "TABLE_HASH_KEY"
        when Groonga::PatriciaTrie
          flags << "TABLE_PAT_KEY"
        end
        if table.domain
          flags << "KEY_NORMALIZE" if table.normalize_key?
          if table.is_a?(Groonga::PatriciaTrie) and table.register_key_with_sis?
            flags << "KEY_WITH_SIS"
          end
        end
        parameters << "#{flags.join('|')}"
        if table.domain
          parameters << "--key_type #{table.domain.name}"
        end
        if table.range
          parameters << "--value_type #{table.range.name}"
        end
        if table.domain
          default_tokenizer = table.default_tokenizer
          if default_tokenizer
            parameters << "--default_tokenizer #{default_tokenizer.name}"
          end
        end
        write("table_create #{table.name} #{parameters.join(' ')}\n")
      end

      def create_table_footer(table)
      end

      def change_table_header(table)
      end

      def change_table_footer(table)
      end

      def define_column(table, column)
        parameters = []
        parameters << table.name
        parameters << column.local_name
        flags = []
        if column.scalar?
          flags << "COLUMN_SCALAR"
        elsif column.vector?
          flags << "COLUMN_VECTOR"
        end
        # TODO: support COMPRESS_ZLIB and COMPRESS_LZO?
        parameters << "#{flags.join('|')}"
        parameters << "#{column.range.name}"
        write("column_create #{parameters.join(' ')}\n")
      end

      def define_reference_column(table, column)
        define_column(table, column)
      end

      def define_index_column(table, column)
        parameters = []
        parameters << table.name
        parameters << column.local_name
        flags = []
        flags << "COLUMN_INDEX"
        flags << "WITH_SECTION" if column.with_section?
        flags << "WITH_WEIGHT" if column.with_weight?
        flags << "WITH_POSITION" if column.with_position?
        parameters << "#{flags.join('|')}"
        parameters << "#{column.range.name}"
        source_names = column.sources.collect do |source|
          if source.is_a?(Groonga::Table)
            "_key"
          else
            source.local_name
          end
        end
        parameters << "#{source_names.join(',')}" unless source_names.empty?
        write("column_create #{parameters.join(' ')}\n")
      end
    end
  end

  class TableDumper
    def initialize(table, options={})
      @table = table
      @options = options
      @output = @options[:output]
      @have_output = !@output.nil?
      @output ||= Dumper.default_output
      @error_output = @options[:error_output]
    end

    def dump
      dump_load_command
      if @have_output
        nil
      else
        @output.string
      end
    end

    private
    def write(content)
      @output.write(content)
    end

    def error_write(content)
      return if @error_output.nil?
      @error_output.write(content)
    end

    def dump_load_command
      write("load --table #{@table.name}\n")
      write("[\n")
      columns = available_columns
      dump_columns(columns)
      dump_records(columns)
      write("\n]\n")
    end

    def dump_columns(columns)
      column_names = columns.collect do |column|
        column.local_name
      end
      write(column_names.to_json)
    end

    def dump_records(columns)
      @table.each(:order_by => @options[:order_by]) do |record|
        write(",\n")
        values = columns.collect do |column|
          resolve_value(record, column, column[record.id])
        end
        write(values.to_json)
      end
    end

    def resolve_value(record, column, value)
      case value
      when ::Array
        value.collect do |v|
          resolve_value(record, column, v)
        end
      when Groonga::Record
        if value.support_key?
          value = value.key
        else
          value = value.id
        end
        resolve_value(record, column, value)
      when Time
        # TODO: groonga should support UTC format literal
        # value.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
        value.to_f
      when NilClass
        # TODO: remove me. nil reference column value
        # doesn't accept null.
        ""
      else
        return value unless value.respond_to?(:valid_encoding?)
        sanitized_value = ""
        value = fix_encoding(value)
        value.each_char do |char|
          if char.valid_encoding?
            sanitized_value << char
          else
            table_name = record.table.name
            record_id = record.record_id
            column_name = column.local_name
            error_write("warning: ignore invalid encoding character: " +
                          "<#{table_name}[#{record_id}].#{column_name}>: " +
                          "<#{inspect_invalid_char(char)}>: " +
                          "before: <#{sanitized_value}>\n")
          end
        end
        sanitized_value
      end
    end

    def fix_encoding(value)
      if value.encoding == ::Encoding::ASCII_8BIT
        value.force_encoding(@table.context.ruby_encoding)
      end
      value
    end

    def inspect_invalid_char(char)
      bytes_in_hex = char.bytes.collect do |byte|
        "%#0x" % byte
      end
      bytes_in_hex.join(" ")
    end

    def available_columns
      columns = []
      if @table.support_key?
        columns << @table.column("_key")
      else
        columns << @table.column("_id")
      end
      columns << @table.column("_value") unless @table.range.nil?
      data_columns = @table.columns.reject do |column|
        column.index?
      end
      sorted_columns = data_columns.sort_by do |column|
        column.local_name
      end
      columns.concat(sorted_columns)
      columns
    end
  end
end
