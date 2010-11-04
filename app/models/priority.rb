class Priority < ActiveRecord::Base
  
  include ActionView::Helpers::DateHelper
  

  named_scope :published, :conditions => "priorities.status = 'published'"
  named_scope :unpublished, :conditions => "priorities.status not in ('published','abusive')"

  named_scope :flagged, :conditions => "flags_count > 0"

  named_scope :alphabetical, :order => "priorities.name asc"
  named_scope :newest, :order => "priorities.published_at desc, priorities.created_at desc"
  named_scope :tagged, :conditions => "(priorities.cached_issue_list is not null and priorities.cached_issue_list <> '')"
  named_scope :untagged, :conditions => "(priorities.cached_issue_list is null or priorities.cached_issue_list = '')", :order => "priorities.created_at desc"

  named_scope :by_most_recent_status_change, :order => "priorities.status_changed_at desc"
  
  named_scope :since, lambda{|time| {:conditions=>["priorities.created_at>?",time]}}
  
  named_scope :item_limit, lambda{|limit| {:limit=>limit}} 

  named_scope :by_tag_name, lambda{|tag_name| {:conditions=>["cached_issue_list=?",tag_name]}}

  named_scope :by_user_id, lambda{|user_id| {:conditions=>["user_id=?",user_id]}}

  belongs_to :user
  
  has_many :relationships, :dependent => :destroy
  has_many :incoming_relationships, :foreign_key => :other_priority_id, :class_name => "Relationship", :dependent => :destroy
  
  has_many :activities, :dependent => :destroy

  has_many :notifications, :as => :notifiable, :dependent => :destroy
  
  has_many :reactions
  
  acts_as_taggable_on :issues
  
  liquid_methods :id, :name, :activity_id, :content, :user, :activity, :show_url

  define_index do
    indexes name
    indexes cached_issue_list, :facet=>true
  end
  
  #validates_length_of :name, :within => 3..60
  #validates_uniqueness_of :name
  
  # docs: http://www.practicalecommerce.com/blogs/post/122-Rails-Acts-As-State-Machine-Plugin
  acts_as_state_machine :initial => :published, :column => :status
  
  state :passive
  state :draft
  state :published, :enter => :do_publish
  state :deleted, :enter => :do_delete
  state :buried, :enter => :do_bury
  state :inactive
  state :abusive, :enter => :do_abusive
  
  event :publish do
    transitions :from => [:draft, :passive], :to => :published
  end
  
  event :delete do
    transitions :from => [:passive, :draft, :published], :to => :deleted
  end

  event :undelete do
    transitions :from => :deleted, :to => :published, :guard => Proc.new {|p| !p.published_at.blank? }
    transitions :from => :delete, :to => :draft 
  end
  
  event :bury do
    transitions :from => [:draft, :passive, :published, :deleted], :to => :buried
  end
  
  event :deactivate do
    transitions :from => [:draft, :published, :buried], :to => :inactive
  end

  event :abusive do
    transitions :from => :published, :to => :abusive
  end
    
  cattr_reader :per_page
  @@per_page = 25
  
  def to_param
    "#{id}-#{name.parameterize_full}"
  end  
  
  def is_buried?
    status == 'grafið undir'
  end
    
  def is_new?
    return true if not self.attribute_present?("created_at")
    created_at > Time.now-(86400*7)
  end

  def is_published?
    ['published','inactive'].include?(status)
  end
  alias :is_published :is_published?
          
  def reactivate!
    self.status = 'published'
    self.change = nil
    self.save_with_validation(false)
  end
    
  def has_change?
    attribute_present?("change_id") and self.status != 'inactive' and change and not change.is_expired?
  end

  def has_tags?
    attribute_present?("cached_issue_list")
  end
  
  def replaced?
    attribute_present?("change_id") and self.status == 'inactive'
  end
  
  def all_priority_ids_in_same_tags
    ts = Tagging.find(:all, :conditions => ["tag_id in (?) and taggable_type = 'Priority'",taggings.collect{|t|t.tag_id}.uniq.compact])
    return ts.collect{|t|t.taggable_id}.uniq.compact
  end
  
  def show_url
    Government.last.homepage_url + 'priorities/' + to_param
  end
  
  def content
    "#{self.name} - #{self.description}"
  end
  
  # this uses http://is.gd
  def create_short_url
    self.short_url = open('http://is.gd/create.php?longurl=' + show_url, "UserAgent" => "Ruby-ShortLinkCreator").read[/http:\/\/is\.gd\/\w+(?=" onselect)/]
  end

  def do_abusive
    self.user.do_abusive!(notifications)
    self.update_attribute(:flags_count, 0)
  end

  def flag_by_user(user)
    self.increment!(:flags_count)
    for r in User.active.admins
      notifications << NotificationCommentFlagged.new(:sender => user, :recipient => r)    
    end
  end
  
  private
  def do_publish
    self.published_at = Time.now
  end
  
  def do_delete
    activities.each do |a|
      a.delete!
    end
    self.deleted_at = Time.now
  end
  
  def do_undelete
    self.deleted_at = nil
  end  
  
  def do_bury
    # should probably send an email notification to the person who submitted it
    # but not doing anything for now.
  end
end
