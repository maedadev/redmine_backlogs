class ChangeColumnHistoryOnHistory < ActiveRecord::Migration[5.2]
  def self.up
    change_column :rb_issue_history, :history, :mediumtext
  end

  def self.down
    change_column :rb_issue_history, :history, :text
  end
end
