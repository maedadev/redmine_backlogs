require_dependency 'project'

module BacklogsProjectPatch
    def self.included(base) # :nodoc:
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)

      base.class_eval do
        unloadable if respond_to?(:unloadable)
        has_many :releases, -> { order "#{RbRelease.table_name}.release_start_date DESC, #{RbRelease.table_name}.name DESC" }, :class_name => 'RbRelease', :inverse_of => :project, :dependent => :destroy
        has_many :releases_multiview, :class_name => 'RbReleaseMultiview', :dependent => :destroy
        include Backlogs::ActiveRecord::Attributes
      end
    end

    module ClassMethods
    end

    module InstanceMethods

      def scrum_statistics
        ## pretty expensive to compute, so if we're calling this multiple times, return the cached results
        @scrum_statistics ||= Backlogs::Statistics.new(self)
      end

      def rb_project_settings
        RbProjectSettings.where(:project_id => self.id).first_or_create
      end

      def projects_in_shared_product_backlog
        #sharing off: only the product itself is in the product backlog
        #sharing on: subtree is included in the product backlog
        if Backlogs.setting[:sharing_enabled] and self.rb_project_settings.show_stories_from_subprojects
          self.self_and_descendants.visible.active
        else
          [self]
        end
        #TODO have an explicit association map which project shares its issues into other product backlogs
      end

      #return sprints which are
      # 1. open in project,
      # 2. share to project,
      # 3. share to project but are scoped to project and subprojects
      #depending on sharing mode
      def open_shared_sprints(as_version: false)
        if Backlogs.setting[:sharing_enabled]
          order = Backlogs.setting[:sprint_sort_order] == 'desc' ? 'DESC' : 'ASC'
          ret = shared_versions.visible.where(:status => ['open', 'locked']).order("sprint_start_date #{order}, effective_date #{order}")
          ret = ret.collect{|v| v.becomes(RbSprint) } unless as_version
          ret
        else #no backlog sharing
          RbSprint.open_sprints(self)
        end
      end

      #depending on sharing mode
      def closed_shared_sprints(as_version: false)
        if Backlogs.setting[:sharing_enabled]
          order = Backlogs.setting[:sprint_sort_order] == 'desc' ? 'DESC' : 'ASC'
          ret = shared_versions.visible.where(:status => ['closed']).order("sprint_start_date #{order}, effective_date #{order}")
          ret = ret.collect{|v| v.becomes(RbSprint) } unless as_version
          ret
        else #no backlog sharing
          RbSprint.closed_sprints(self)
        end
      end

      def active_sprint
        if @active_sprint.nil?
          time = (Time.zone ? Time.zone : Time).now
          active_sprints = open_shared_sprints(as_version: true).where("#{RbSprint.table_name}.status = 'open' and not (sprint_start_date is null or effective_date is null) and ? >= sprint_start_date and ? <= effective_date",
            time.end_of_day, time.beginning_of_day
          ).collect{|v| v.becomes(RbSprint) }
          @active_sprint = active_sprints.find{|sprint| sprint.stories.find{|story| story.project_id == id }}
        end

        @active_sprint
      end

      def open_releases_by_date
        order = Backlogs.setting[:sprint_sort_order] == 'desc' ? 'DESC' : 'ASC'
        (Backlogs.setting[:sharing_enabled] ? shared_releases : releases).
          visible.open.
          order("#{RbRelease.table_name}.release_end_date #{order}, #{RbRelease.table_name}.release_start_date #{order}")
      end

      def closed_releases_by_date
        order = Backlogs.setting[:sprint_sort_order] == 'desc' ? 'DESC' : 'ASC'
        (Backlogs.setting[:sharing_enabled] ? shared_releases : releases).
          visible.closed.
          order("#{RbRelease.table_name}.release_end_date #{order}, #{RbRelease.table_name}.release_start_date #{order}")
      end

      def shared_releases
        if new_record?
          RbRelease.joins(:project).includes(:project).
                    where("#{Project.table_name}.status <> #{Project::STATUS_ARCHIVED} AND #{RbRelease.table_name}.sharing = 'system'")
        else
          @shared_releases ||= begin
            order = Backlogs.setting[:sprint_sort_order] == 'desc' ? 'DESC' : 'ASC'
            r = root? ? self : root
            RbRelease.joins(:project).includes(:project).where("#{Project.table_name}.id = #{id}" +
                " OR (#{Project.table_name}.status <> #{Project::STATUS_ARCHIVED} AND (" +
                  " #{RbRelease.table_name}.sharing = 'system'" +
                  " OR (#{Project.table_name}.lft >= #{r.lft} AND #{Project.table_name}.rgt <= #{r.rgt} AND #{RbRelease.table_name}.sharing = 'tree')" +
                  " OR (#{Project.table_name}.lft < #{lft} AND #{Project.table_name}.rgt > #{rgt} AND #{RbRelease.table_name}.sharing IN ('hierarchy', 'descendants'))" +
                  " OR (#{Project.table_name}.lft > #{lft} AND #{Project.table_name}.rgt < #{rgt} AND #{RbRelease.table_name}.sharing = 'hierarchy')" +
                "))").
              order("#{RbRelease.table_name}.release_end_date #{order}, #{RbRelease.table_name}.release_start_date #{order}")
          end
        end
      end


      # Returns a list of releases each project's stories can be dropped to on the master backlog.
      # Notice it is disallowed to drop stories from sprints to releases if the stories are owned
      # by parent projects which are out of scope of the currently selected project as they will
      # disappear when dropped.
      def droppable_releases
        self.class.connection.select_all(_sql_for_droppables(RbRelease.table_name,true))
      end

      # Return a list of sprints each project's stories can be dropped to on the master backlog.
      def droppable_sprints
        self.class.connection.select_all(_sql_for_droppables(Version.table_name))
      end

private

      # Returns sql for getting a list of projects and for each project which releases/sprints stories from the corresponding
      # project can be dropped to on the master backlog.
      # name: table_name for either RbRelease or Version (needs to have fields project_id and sharing)
      # scoped_subproject: if true only subprojects are considered effectively disallowing dropping any issues from parent projects.
      def _sql_for_droppables(name,scoped_subproject = false)
        r = scoped_subproject ? self : self.root
        sql = "SELECT pp.id as project," + _sql_for_aggregate_list("drp.id") +
          " FROM #{name} drp " +
          " LEFT JOIN #{Project.table_name} pp on drp.project_id = pp.id" +
            " OR (pp.status <> #{Project::STATUS_ARCHIVED} AND (" +
              " drp.sharing = 'system'" +
              " OR (drp.sharing = 'tree' AND (" +
                "pp.lft >= (SELECT p.lft from #{Project.table_name} p WHERE " +
                  "p.lft < (SELECT p1.lft from #{Project.table_name} p1 WHERE p1.id=drp.project_id) AND " +
                  "p.rgt > (SELECT p1.rgt from #{Project.table_name} p1 WHERE p1.id=drp.project_id) AND p.parent_id IS NULL) AND " +
                "pp.rgt <= (SELECT p.rgt from #{Project.table_name} p WHERE " +
                  "p.lft < (SELECT p1.lft from #{Project.table_name} p1 WHERE p1.id=drp.project_id) AND " +
                  "p.rgt > (SELECT p1.rgt from #{Project.table_name} p1 WHERE p1.id=drp.project_id) AND p.parent_id IS NULL)" +
              "))" +
              " OR (drp.sharing IN ('hierarchy', 'descendants') AND (" +
                "pp.lft >= (SELECT p.lft from #{Project.table_name} p WHERE p.id=drp.project_id) AND " +
                "pp.rgt <= (SELECT p.rgt from #{Project.table_name} p WHERE p.id=drp.project_id)" +
              ")) " +
              " OR (drp.sharing = 'hierarchy' AND (" +
                "pp.lft < (SELECT p.lft from #{Project.table_name} p WHERE p.id=drp.project_id) AND " +
                "pp.rgt > (SELECT p.rgt from #{Project.table_name} p WHERE p.id=drp.project_id)"+
              "))" +
          "))" +
          " WHERE pp.lft >= #{r.lft} AND pp.rgt <= #{r.rgt}" +
                # exclude 'closed' versions or releases.
                # NOTE: both tables have 'status' column and 'closed' value.
                " AND drp.status <> 'closed'" +
          " GROUP BY pp.id;"
        sql
      end

      # Returns sql for aggregating a list from grouped rows. Depends on database implementation.
      def _sql_for_aggregate_list(field_name)
        adapter_name = self.class.connection.adapter_name.downcase
        aggregate_list = ""
        if adapter_name.starts_with? 'mysql'
          aggregate_list = " GROUP_CONCAT(#{field_name} SEPARATOR ',') as list "
        elsif adapter_name.starts_with? 'postgresql'
          aggregate_list = " array_to_string(array_agg(#{field_name}),',') as list "
        elsif adapter_name.starts_with? 'sqlite'
          aggregate_list = " GROUP_CONCAT(#{field_name}) as list "
        else
          raise NotImplementedError, "Unknown adapter '#{adapter_name}'"
        end
      end

    end
end

Project.send(:include, BacklogsProjectPatch) unless Project.included_modules.include? BacklogsProjectPatch
