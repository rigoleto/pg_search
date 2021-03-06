# encoding: UTF-8

require "active_support/core_ext/module/delegation"

module PgSearch
  class ScopeOptions
    attr_reader :config, :feature_options, :model

    def initialize(config)
      @config = config
      @model = config.model
      @feature_options = config.feature_options
    end

    def apply(scope)
      scope = include_table_aliasing_for_rank(scope)
      rank_table_alias = scope.pg_search_rank_table_alias(:include_counter)

      scope
        .joins(rank_join(rank_table_alias))
        .order("#{rank_table_alias}.rank DESC, #{order_within_rank}")
        .extend(DisableEagerLoading)
        .extend(WithPgSearchRank)
    end

    # workaround for https://github.com/Casecommons/pg_search/issues/14
    module DisableEagerLoading
      def eager_loading?
        return false
      end
    end

    module WithPgSearchRank
      def with_pg_search_rank
        scope = self
        scope = scope.select("*") unless scope.select_values.any?
        scope.select("#{pg_search_rank_table_alias}.rank AS pg_search_rank")
      end
    end

    module PgSearchRankTableAliasing
      def pg_search_rank_table_alias(include_counter = false)
        components = [arel_table.name]
        if include_counter
          count = pg_search_scope_application_count_plus_plus
          components << count if count > 0
        end

        Configuration.alias(components)
      end

      private

      attr_writer :pg_search_scope_application_count
      def pg_search_scope_application_count
        @pg_search_scope_application_count ||= 0
      end

      def pg_search_scope_application_count_plus_plus
        count = pg_search_scope_application_count
        self.pg_search_scope_application_count = pg_search_scope_application_count + 1
        count
      end
    end

    private

    delegate :connection, :quoted_table_name, :to => :model

    def subquery
      model
        .unscoped
        .select("#{primary_key} AS pg_search_id")
        .select("#{rank} AS rank")
        .joins(subquery_join)
        .where(conditions)
        .limit(nil)
        .offset(nil)
    end

    def conditions
      config.features.reject do |_feature_name, feature_options|
        feature_options && feature_options[:sort_only]
      end.map do |feature_name, _feature_options|
        feature_for(feature_name).conditions
      end.inject do |accumulator, expression|
        Arel::Nodes::Or.new(accumulator, expression)
      end.to_sql
    end

    def order_within_rank
      config.order_within_rank || "#{primary_key} ASC"
    end

    def primary_key
      "#{quoted_table_name}.#{connection.quote_column_name(model.primary_key)}"
    end

    def subquery_join
      if config.associations.any? # rubocop:disable Style/GuardClause
        config.associations.map do |association|
          association.join(primary_key)
        end.join(' ')
      end
    end

    FEATURE_CLASSES = {
      :dmetaphone => Features::DMetaphone,
      :tsearch => Features::TSearch,
      :trigram => Features::Trigram
    }

    def feature_for(feature_name) # rubocop:disable Metrics/AbcSize
      feature_name = feature_name.to_sym
      feature_class = FEATURE_CLASSES[feature_name]

      raise ArgumentError.new("Unknown feature: #{feature_name}") unless feature_class

      normalizer = Normalizer.new(config)

      feature_class.new(
        config.query,
        feature_options[feature_name],
        config.columns,
        config.model,
        normalizer
      )
    end

    def rank
      (config.ranking_sql || ":tsearch").gsub(/:(\w*)/) do
        feature_for($1).rank.to_sql
      end
    end

    def rank_join(rank_table_alias)
      "INNER JOIN (#{subquery.to_sql}) AS #{rank_table_alias} ON #{primary_key} = #{rank_table_alias}.pg_search_id"
    end

    def include_table_aliasing_for_rank(scope)
      if scope.included_modules.include?(PgSearchRankTableAliasing)
        scope
      else
        (::ActiveRecord::VERSION::MAJOR < 4 ? scope.scoped : scope.all.spawn).tap do |new_scope|
          new_scope.class_eval { include PgSearchRankTableAliasing }
        end
      end
    end
  end
end

