class ChangeColumnPositionOnIssue < ActiveRecord::Migration[5.2]
  def self.up
    change_column :issues, :position, :integer, :null => false, :default => 0
  end

  def self.down
    change_column :issues, :position, :integer, :null => false
  end
end
