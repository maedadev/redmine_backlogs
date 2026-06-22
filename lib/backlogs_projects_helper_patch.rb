require_dependency 'projects_helper'

module BacklogsProjectsHelperPatch
    def project_settings_tabs
      tabs = super
      tabs << {:name => 'backlogs',
        :action => :manage_project_backlogs,
        :partial => 'backlogs/project_settings',
        :label => :label_backlogs
      } if @project.module_enabled?('backlogs') and 
           User.current.allowed_to?(:configure_backlogs, nil, :global=>true)
      return tabs
    end

end

module ProjectsHelper
  unloadable if respond_to?(:unloadable)
  prepend BacklogsProjectsHelperPatch
end
