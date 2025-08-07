require_dependency 'issue'

module BacklogsNestedSetPatch
  def self.included(base) # :nodoc:
    base.extend(ClassMethods)
    base.send(:include, InstanceMethods)
  end

  module ClassMethods
  end

  module InstanceMethods
    def right_sibling
      siblings.where(["#{self.class.table_name}.lft > ?", lft]).first
    end

    def move_to(target, position)
      if Gem::Version.new(Redmine::VERSION.to_s) >= Gem::Version.new('5.1.1')
        # 新しい Redmine：ブロック形式のロック
        lock_nested_set do
          perform_move(target, position)
        end
      else
        # 古い Redmine：明示的にロック
        lock_nested_set
        begin
          perform_move(target, position)
        ensure
          unlock_nested_set
        end
      end

      reload_nested_set_values
    end

    # Move the node to the left of another node
    def move_to_left_of(node)
      move_to node, :left
    end

    # Move the node to the left of another node
    def move_to_right_of(node)
      move_to node, :right
    end

    private

    def perform_move(target, position)
      reload_nested_set_values

      if !root? && !move_possible?(target)
        raise ImpossibleMove, "Impossible move, target node cannot be inside moved tree."
      end

      bound, other_bound = get_boundaries(target, position)

      # there would be no change
      return if bound == rgt || bound == lft

      # we have defined the boundaries of two non-overlapping intervals,
      # so sorting puts both the intervals and their boundaries in order
      a, b, c, d = [lft, rgt, bound, other_bound].sort

      where_statement(a, d).update_all(
        conditions(a, b, c, d, target, position)
      )
    end

    class ImpossibleMove < ActiveRecord::StatementInvalid
    end

    def get_boundaries(target, position)
      right = rgt
      left = lft
      if (bound = target_bound(target, position)) > right
        bound -= 1
        other_bound = right + 1
      else
        other_bound = left - 1
      end
      [bound, other_bound]
    end

    def target_bound(target, position)
      case position
      when :child then target[:rgt]
      when :left  then target[:lft]
      when :right then target[:rgt] + 1
      when :root  then nested_set_scope.pluck(:rgt).max + 1
      else raise ActiveRecord::ActiveRecordError, "Position should be :child, :left, :right or :root ('#{position}' received)."
      end
    end

    def new_parent_id(target, position)
      case position
      when :child then target.id
      when :root  then nil
      else target[:parent_id]
      end
    end

    def conditions(a, b, c, d, target, position)
      _conditions = case_condition_for_direction("lft") +
        case_condition_for_direction("rgt") +
        case_condition_for_parent

      [
        _conditions,
        {
          :a => a, :b => b, :c => c, :d => d,
          :primary_id => self.id,
          :new_parent_id => new_parent_id(target, position),
          :timestamp => Time.now.utc
        }
      ]
    end

    def where_statement(left_bound, right_bound)
      self.class.where(:root_id => root_id).where(:lft => left_bound..right_bound).
        or(self.class.where(:root_id => root_id).where(:rgt => left_bound..right_bound))
    end

    def case_condition_for_direction(column_name)
      column = column_name
      "#{column} = CASE " +
        "WHEN #{column} BETWEEN :a AND :b " +
        "THEN #{column} + :d - :b " +
        "WHEN #{column} BETWEEN :c AND :d " +
        "THEN #{column} + :a - :c " +
        "ELSE #{column} END, "
    end

    def case_condition_for_parent
      "issues.parent_id = CASE " +
        "WHEN issues.id = :primary_id THEN :new_parent_id " +
        "ELSE issues.parent_id END"
    end
  end
end

Issue.send(:include, BacklogsNestedSetPatch) unless Issue.included_modules.include? BacklogsNestedSetPatch

