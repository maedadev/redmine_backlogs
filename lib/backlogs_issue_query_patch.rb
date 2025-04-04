require_dependency 'issue_query'
require 'erb'

module BacklogsIssueQueryPatch

    def joins_for_order_statement(order_options)
      joins = super
      if order_options
        if order_options.include?("#{RbRelease.table_name}")
          joins = "" if joins.nil?
          joins += " LEFT OUTER JOIN #{RbRelease.table_name} ON #{RbRelease.table_name}.id = #{queried_table_name}.release_id"
        end
      end

      joins
    end

    def available_filters
      super
      return @available_filters if !show_backlogs_issue_items?(project)

      if RbStory.trackers.length == 0 or RbTask.tracker.blank?
        backlogs_filters = { }
      else
        backlogs_filters = {
          # mother of *&@&^*@^*#.... order "20" is a magical constant in RM2.2 which means "I'm a custom field". What. The. Fuck.
          "backlogs_issue_type" => { :type => :list,
                                      :name => l(:field_backlogs_issue_type),
                                      :values => [[l(:backlogs_story), "story"], [l(:backlogs_task), "task"], [l(:backlogs_impediment), "impediment"], [l(:backlogs_any), "any"]],
                                      :order => 21 },
          "story_points" => { :type => :float,
                              :name => l(:field_story_points),
                              :order => 22 }
                           }
      end

      if project
        backlogs_filters["release_id"] = {
          :type => :list_optional,
          :name => l(:field_release),
          :values => RbRelease.where(project_id: project).order('name ASC').collect { |d| [d.name, d.id.to_s]},
          :order => 21
        }
      end
    
      backlogs_filters.each do |field, options|
        add_available_filter(field, options)
      end

      @available_filters
    end
      
    def available_columns
      super
      return @available_columns if !show_backlogs_issue_items?(project) or @backlog_columns_included
      
      @backlog_columns_included = true
      
      @available_columns << QueryColumn.new(:story_points, :sortable => "#{Issue.table_name}.story_points")
      @available_columns << QueryColumn.new(:velocity_based_estimate)
      @available_columns << QueryColumn.new(:position, :sortable => "#{Issue.table_name}.position")
      @available_columns << QueryColumn.new(:remaining_hours, :sortable => "#{Issue.table_name}.remaining_hours")
      @available_columns << QueryColumn.new(:release, :sortable => "#{RbRelease.table_name}.name", :groupable => true)
      @available_columns << QueryColumn.new(:backlogs_issue_type)
    end

    def sql_for_field(field, operator, value, db_table, db_field, is_custom_filter=false)
      return super unless field == "backlogs_issue_type"

      db_table = Issue.table_name

      sql = []

      selected_values = values_for(field)
      selected_values = ['story', 'task'] if selected_values.include?('any')

      story_trackers = RbStory.trackers(:type=>:string)
      all_trackers = (RbStory.trackers + [RbTask.tracker]).collect{|val| "#{val}"}.join(",")

      selected_values.each { |val|
        case val
          when "story"
            sql << "(#{db_table}.tracker_id in (#{story_trackers}))"

          when "task"
            sql << "(#{db_table}.tracker_id = #{RbTask.tracker})"

          when "impediment"
            sql << "(#{db_table}.id in (
                              select issue_from_id
                              from issue_relations ir
                              join issues blocked on
                                blocked.id = ir.issue_to_id
                                and blocked.tracker_id in (#{all_trackers})
                              where ir.relation_type = 'blocks'
                            ))"
        end
      }

      case operator
        when "="
          sql = sql.join(" or ")

        when "!"
          sql = "not (" + sql.join(" or ") + ")"
      end

      return sql
    end

    private
    def show_backlogs_issue_items?(project)
      !project.nil? and project.module_enabled?('backlogs')
    end

end

IssueQuery.prepend(BacklogsIssueQueryPatch)
