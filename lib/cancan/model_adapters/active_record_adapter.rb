module CanCan
  module ModelAdapters
    module ActiveRecordAdapter
      # Returns conditions intended to be used inside a database query. Normally you will not call this
      # method directly, but instead go through ModelAdditions#accessible_by.
      #
      # If there is only one "can" definition, a hash of conditions will be returned matching the one defined.
      #
      #   can :manage, User, :id => 1
      #   query(:manage, User).conditions # => { :id => 1 }
      #
      # If there are multiple "can" definitions, a SQL string will be returned to handle complex cases.
      #
      #   can :manage, User, :id => 1
      #   can :manage, User, :manager_id => 1
      #   cannot :manage, User, :self_managed => true
      #   query(:manage, User).conditions # => "not (self_managed = 't') AND ((manager_id = 1) OR (id = 1))"
      #
      def conditions(excluded_keys)
        if @rules.size == 1 && @rules.first.base_behavior
          # Return the conditions directly if there's just one definition
          @rules.first.custom_where_conditions || tableized_conditions(excluded_keys, @rules.first.conditions).dup
        else
          @rules.reverse.inject(false_sql) do |sql, rule|
            custom_conditions = rule.custom_where_conditions
            to_merge = custom_conditions || tableized_conditions(excluded_keys, rule.conditions).dup
            merge_conditions(sql, to_merge, rule.base_behavior)
          end
        end
      end

      def tableized_conditions(excluded_keys, conditions, model_class = @model_class, parent_result_hash = {}, store_on_parent = false)
        return conditions unless conditions.kind_of? Hash

        excluded_key = excluded_keys.shift

        conditions.inject(Hash.new{}) do |result_hash, (name, value)|
          if value.kind_of? Hash
            association_class = model_class.reflect_on_association(name).klass.name.constantize
            table_name = model_class.reflect_on_association(name).table_name.to_sym
            value = tableized_conditions(excluded_keys, value, association_class, result_hash, excluded_key == name)
          end

          if store_on_parent && value.kind_of(Hash)
            parent_result_hash[table_name] = value if value.present?
          elsif !value.kind_of?(Hash) || value.present?
            result_hash[table_name || name] = value
          end

          result_hash
        end
      end

      # Returns the associations used in conditions for the :joins option of a search.
      # See ModelAdditions#accessible_by
      def joins
        joins_hash = {}
        @rules.each do |rule|
          associations_hash = rule.custom_where_conditions ? rule.conditions : rule.associations_hash
          merge_joins(joins_hash, associations_hash)
        end

        if joins_hash.empty?
          [joins_hash, []]
        else
          clean_joins(joins_hash)
        end
      end

      def database_records
        scope = override_scope

        if scope != false
          @model_class.where(nil).merge(scope)
        elsif @model_class.respond_to?(:where) && @model_class.respond_to?(:joins)
          # if any one rule has no conditions (e.g. it always applies), then there's no reason to filter at all

          if !@rules.detect { |rule| rule.conditions_empty? }.nil?
            @model_class.where(nil)
          else
            mergeable_conditions = mergeable_conditions?
            if mergeable_conditions
              join_array, exclude_keys = joins
              @model_class.where(conditions(exclude_keys)).joins(join_array)
              # build_relation(*(@rules.map(&:conditions)))
            else
              join_array, exclude_keys = joins
              conditions_sql = @rules.map { |rule| "(#{sanitize_sql(rule.where_conditions)})" }
              conditions_sql = conditions_sql.join(" OR ")
              #TODO should use build_relation?
              @model_class.where(conditions_sql).joins(join_array)
            end
          end
        else
          @model_class.all(:conditions => conditions, :joins => joins)
        end
      end

      private

      def mergeable_conditions?
        @rules.find { |rule| rule.unmergeable? }.blank?
      end

      def override_scope
        conditions = @rules.map(&:conditions).compact
        if defined?(ActiveRecord::Relation) && conditions.any? { |c| c.kind_of?(ActiveRecord::Relation) }
          if conditions.size == 1
            conditions.first
          elsif conditions.any?(&:empty?)
            nil
          else
            rule = @rules.detect { |rule| rule.conditions.kind_of?(ActiveRecord::Relation) }
            raise Error, "Unable to merge an Active Record scope with other conditions. Instead use a hash or SQL for #{rule.actions.first} #{rule.subjects.first} ability."
          end
        else
          false
        end
      end

      def merge_conditions(sql, conditions_hash, behavior)
        if conditions_hash.blank?
          behavior ? true_sql : false_sql
        else
          conditions = sanitize_sql(conditions_hash)
          case sql
          when true_sql
            behavior ? true_sql : "not (#{conditions})"
          when false_sql
            behavior ? conditions : false_sql
          else
            behavior ? "(#{conditions}) OR (#{sql})" : "not (#{conditions}) AND (#{sql})"
          end
        end
      end

      def false_sql
        sanitize_sql(['?=?', true, false])
      end

      def true_sql
        sanitize_sql(['?=?', true, true])
      end

      def sanitize_sql(conditions)
        @model_class.send(:sanitize_sql, conditions)
      end

      # Takes two hashes and does a deep merge.
      def merge_joins(base, add)
        add.each do |name, nested|
          if base[name].is_a?(Hash)
            merge_joins(base[name], nested) unless nested.empty?
          else
            base[name] = nested
          end
        end
      end

      # Removes empty hashes and moves everything into arrays.
      def clean_joins(joins_hash)
        joins = []
        excluded_keys = []

        joins_hash.each do |name, nested|
          joins << if nested.empty?
            name
          elsif !nested.kind_of? Hash
            { name => nested }
          else
            excluded_keys << name
            { name => clean_joins(nested).first }
          end
        end

        [joins, excluded_keys]
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  include CanCan::ModelAdditions
end
