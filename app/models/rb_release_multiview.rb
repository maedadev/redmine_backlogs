class RbReleaseMultiview < ActiveRecord::Base
  self.table_name = 'rb_releases_multiview'

  belongs_to :project

  if Rails.gem_version >= Gem::Version.new('7.1')
    serialize :release_ids, coder: YAML
  else
    serialize :release_ids
  end
  validates_presence_of :project_id, :name
  validates_length_of :name, :maximum => 64

  include Backlogs::ActiveRecord::Attributes

  def releases
    RbRelease.where(id: self.release_ids)
            .order("release_end_date ASC, release_start_date ASC").all
  end

  def has_burnchart?
    false #FIXME release burndown broken
    #releases.inject(false) {|result,release| result |= release.has_burndown?}
  end

  def burnchart
    return nil #FIXME release burndown broken
    #return nil unless self.has_burnchart?
    #@cached_burnchart ||= RbReleaseMultiviewBurnchart.new(self)
    #return @cached_burnchart
  end

end
