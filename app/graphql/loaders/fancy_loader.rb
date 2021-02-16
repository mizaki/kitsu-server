class Loaders::FancyLoader < GraphQL::Batch::Loader
  include Loaders::FancyLoader::DSL


  end

  def initialize(find_by:, limit:, offset: 0, sort:, token:)
    @find_by = find_by
    @limit = limit
    @offset = offset
    @sort = sort.map(&:to_h)
    @token = token
  end

  def perform(keys)
    relation = model.where(@find_by => keys)
    query = scope.new(@token, relation).resolve
    # Drop down into Arel so we can have fun
    query_arel = query.arel
    table = query.arel_table

    # Apply the transform and column lambdas for the sorting requested
    query_arel = @sort.inject(query_arel) do |arel, sort|
      if sorts[sort[:on]][:transform]
        sorts[sort[:on]][:transform].call(arel)
      else
        arel
      end
    end
    orders = @sort.map do |sort|
      sorts[sort[:on]][:column].call.public_send(sort[:direction])
    end

    # Build up a window function with the sorting applied
    partition = Arel::Nodes::Window.new
                                   .partition(table[@find_by])
                                   .order(orders)
    row_number = Arel::Nodes::NamedFunction.new('ROW_NUMBER', [])
                                           .over(partition)
                                           .as('row_number')

    # Select the row number, shove it into a subquery, then set up our offset and limit
    query_arel.project(row_number)
    subquery = query_arel.as('subquery')
    offset = subquery[:row_number].gt(@offset)
    limit = subquery[:row_number].lteq(@offset + @limit)

    # Finally, go *back* to the ActiveRecord model, and do the final select
    records = model.select(Arel.star).from(subquery).where(offset.and(limit)).to_a
    results = records.group_by { |rec| rec[@find_by] }
    keys.each do |key|
      fulfill(key, results[key] || [])
    end
  end

  private

  def scope
    @scope ||= Pundit::PolicyFinder.new(model).scope!
  end
end
