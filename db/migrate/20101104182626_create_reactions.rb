class CreateReactions < ActiveRecord::Migration
  def self.up
    create_table :reactions do |t|
      t.references :user
      t.references :priority
      t.boolean :like
      t.boolean :dislike

      t.timestamps
    end
  end

  def self.down
    drop_table :reactions
  end
end
