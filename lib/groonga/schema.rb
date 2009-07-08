# -*- coding: utf-8 -*-
#
# Copyright (C) 2009  Kouhei Sutou <kou@clear-code.com>
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

module Groonga
  class Schema
    class << self
      def define(options={})
        schema = new(options)
        yield(schema)
        schema.define
      end

      def create_table(name, options={}, &block)
        define do |schema|
          schema.define_table(name, options, &block)
        end
      end

      def dump(options={})
        Dumper.new(options).dump
      end
    end

    def initialize(options={})
      @options = (options || {}).dup
      @definitions = []
    end

    def define
      @definitions.each do |definition|
        definition.define
      end
    end

    def define_table(name, options={})
      definition = TableDefinition.new(name, @options.merge(options || {}))
      yield(definition)
      @definitions << definition
    end

    class TableDefinition
      def initialize(name, options)
        @name = name
        @name = @name.to_s if @name.is_a?(Symbol)
        @columns = []
        @options = options
        @table_type = table_type
      end

      def define
        table = @table_type.create(:name => @name, :path => @options[:path])
        @columns.each do |column|
          column.define(table)
        end
        table
      end

      def column(name, type, options={})
        column = self[name] || ColumnDefinition.new(name, options)
        column.type = type
        column.options.merge!(options)
        @columns << column unless @columns.include?(column)
        self
      end

      def integer32(name, options={})
        column(name, "<int>", options)
      end
      alias_method :integer, :integer32
      alias_method :int32, :integer32

      def integer64(name, options={})
        column(name, "<int64>", options)
      end
      alias_method :int64, :integer64

      def unsigned_integer32(name, options={})
        column(name, "<uint>", options)
      end
      alias_method :unsigned_integer, :unsigned_integer32
      alias_method :uint32, :unsigned_integer32

      def unsigned_integer64(name, options={})
        column(name, "<uint64>", options)
      end
      alias_method :uint64, :unsigned_integer64

      def float(name, options={})
        column(name, "<float>", options)
      end

      def time(name, options={})
        column(name, "<time>", options)
      end

      def short_text(name, options={})
        column(name, "<shorttext>", options)
      end
      alias_method :string, :short_text

      def text(name, options={})
        column(name, "<text>", options)
      end

      def long_text(name, options={})
        column(name, "<longtext>", options)
      end

      def index(name, target_column, options={})
        column = self[name] || IndexColumnDefinition.new(name, options)
        column.target = target_column
        column.options.merge!(options)
        @columns << column unless @columns.include?(column)
        self
      end

      def [](name)
        @columns.find {|column| column.name == name}
      end

      private
      def table_type
        type = @options[:type]
        case type
        when :array, nil
          Groonga::Array
        when :hash
          Groonga::Hash
        when :patricia_trie
          Groonga::PatriciaTrie
        else
          raise ArgumentError, "unknown table type: #{type.inspect}"
        end
      end

      def context
        @options[:context] || Groonga::Context.default
      end
    end

    class ColumnDefinition
      attr_accessor :name, :type
      attr_reader :options

      def initialize(name, options={})
        @name = name
        @name = @name.to_s if @name.is_a?(Symbol)
        @options = (options || {}).dup
        @type = nil
      end

      def define(table)
        table.define_column(@name,
                            normalize_type(@type),
                            @options)
      end

      def normalize_type(type)
        return type if type.is_a?(Groonga::Object)
        case type.to_s
        when "string"
          "<shorttext>"
        when "text"
          "<text>"
        when "integer"
          "<int>"
        when "float"
          "<float>"
        when "decimal"
          "<int64>"
        when "datetime", "timestamp", "time", "date"
          "<time>"
        when "binary"
          "<longtext>"
        when "boolean"
          "<int>"
        else
          type
        end
      end
    end

    class IndexColumnDefinition
      attr_accessor :name, :target
      attr_reader :options

      def initialize(name, options={})
        @name = name
        @name = @name.to_s if @name.is_a?(Symbol)
        @options = (options || {}).dup
        @target = nil
      end

      def define(table)
        target = @target
        target = context[target] unless target.is_a?(Groonga::Object)
        index = table.define_index_column(@name,
                                          target.table,
                                          @options)
        index.source = target
        index
      end

      private
      def context
        @options[:context] || Groonga::Context.default
      end
    end

    class Dumper
      def initialize(options={})
        @options = (options || {}).dup
      end

      def dump
        context = @options[:context] || Groonga::Context.default
        database = context.database
        return nil if database.nil?

        schema = ""
        database.each do |object|
          next unless object.is_a?(Groonga::Table)
          next if object.name == "<ranguba:objects>"
          schema << "define_table(#{object.name.inspect}) do |table|\n"
          object.columns.each do |column|
            type = column_method(column)
            name = column.local_name
            schema << "  table.#{type}(#{name.inspect})\n"
          end
          schema << "end\n"
        end
        schema
      end

      private
      def column_method(column)
        case column.range.name
        when "<int>"
          "integer32"
        when "<int64>"
          "integer64"
        when "<uint>"
          "unsigned_integer32"
        when "<uint64>"
          "unsigned_integer64"
        when "<float>"
          "float"
        when "<time>"
          "time"
        when "<shorttext>"
          "short_text"
        when "<text>"
          "text"
        when "<longtext>"
          "long_text"
        else
          raise ArgumentError, "unsupported column: #{column.inspect}"
        end
      end
    end
  end
end
