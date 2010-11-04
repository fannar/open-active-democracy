require 'digest/sha1'
require 'rubygems'
require 'nokogiri'
gem 'soap4r'
require 'soap/rpc/driver'
require 'soap/wsdlDriver'  

class User < ActiveRecord::Base
  
  extend ActiveSupport::Memoizable
  require 'paperclip'
  
  named_scope :active, :conditions => "users.status in ('pending','active')"
  named_scope :newsletter_subscribed, :conditions => "users.is_newsletter_subscribed = true and users.email is not null and users.email <> ''"
  named_scope :comments_unsubscribed, :conditions => "users.is_comments_subscribed = false"  
  named_scope :twitterers, :conditions => "users.twitter_login is not null and users.twitter_login <> ''"
  named_scope :authorized_twitterers, :conditions => "users.twitter_token is not null"
  named_scope :uncrawled_twitterers, :conditions => "users.twitter_crawled_at is null"
  named_scope :contributed, :conditions => "users.document_revisions_count > 0 or users.point_revisions_count > 0"
  named_scope :no_recent_login, :conditions => "users.loggedin_at < '#{Time.now-90.days}'"
  named_scope :admins, :conditions => "users.is_admin = true"
  named_scope :suspended, :conditions => "users.status = 'suspended'"
  named_scope :probation, :conditions => "users.status = 'probation'"
  named_scope :deleted, :conditions => "users.status = 'deleted'"
  named_scope :pending, :conditions => "users.status = 'pending'"  
  named_scope :warnings, :conditions => "warnings_count > 0"
  named_scope :no_branch, :conditions => "branch_id is null"
  named_scope :with_branch, :conditions => "branch_id is not null"
  
  named_scope :by_talkative, :conditions => "users.comments_count > 0", :order => "users.comments_count desc"
  named_scope :by_twitter_count, :order => "users.twitter_count desc"
  named_scope :by_recently_created, :order => "users.created_at desc"
  named_scope :by_revisions, :order => "users.document_revisions_count+users.point_revisions_count desc"
  named_scope :by_invites_accepted, :conditions => "users.contacts_invited_count > 0", :order => "users.referrals_count desc"
  named_scope :by_suspended_at, :order => "users.suspended_at desc"
  named_scope :by_deleted_at, :order => "users.deleted_at desc"
  named_scope :by_recently_loggedin, :order => "users.loggedin_at desc"
  named_scope :by_probation_at, :order => "users.probation_at desc"
  named_scope :by_oldest_updated_at, :order => "users.updated_at asc"
  named_scope :by_twitter_crawled_at, :order => "users.twitter_crawled_at asc"
  
  named_scope :item_limit, lambda{|limit| {:limit=>limit}}
  
  belongs_to :picture
  has_attached_file :buddy_icon, :styles => { :icon_24 => "24x24#", :icon_35 => "35x35#", :icon_48 => "48x48#", :icon_96 => "96x96#" }
  
  validates_attachment_size :buddy_icon, :less_than => 5.megabytes
  validates_attachment_content_type :buddy_icon, :content_type => ['image/jpeg', 'image/png', 'image/gif']
  
  belongs_to :branch
  belongs_to :referral, :class_name => "User", :foreign_key => "referral_id"
  
  has_one :profile, :dependent => :destroy
  
  has_many :unsubscribes, :dependent => :destroy
  has_many :signups
  
  has_many :priorities, :conditions => "endorsements.status = 'active'", :through => :endorsements
  has_many :finished_priorities, :conditions => "endorsements.status = 'finished'", :through => :endorsements, :source => :priority
  
  has_many :created_priorities, :class_name => "Priority"
  
  has_many :activities, :dependent => :destroy
  has_many :questions, :dependent => :destroy
  has_many :point_revisions, :class_name => "Revision", :dependent => :destroy
  has_many :documents, :dependent => :destroy  
  has_many :document_revisions, :class_name => "DocumentRevision", :dependent => :destroy
  
  has_many :comments, :dependent => :destroy
  has_many :blasts, :dependent => :destroy
  
  has_many :sent_notifications, :foreign_key => "sender_id", :class_name => "Notification"
  has_many :received_notifications, :foreign_key => "recipient_id", :class_name => "Notification"
  has_many :notifications, :as => :notifiable, :dependent => :nullify # this is for notificiations about them, not notifications they've given or received
  
  has_many :following_discussions, :dependent => :destroy
  has_many :following_discussion_activities, :through => :following_discussions, :source => :activity

  has_many :reactions
  
  liquid_methods :first_name, :last_name, :id, :name, :login, :activation_code, :email, :root_url, :profile_url, :unsubscribe_url
  
  validates_presence_of     :login, :message => I18n.t('users.new.validation.login')
  validates_length_of       :login, :within => 3..40
  validates_uniqueness_of   :login, :case_sensitive => false    
  
  validates_length_of       :email, :within => 3..100
  validates_uniqueness_of   :email, :case_sensitive => false
  validates_uniqueness_of   :facebook_uid, :allow_nil => true
  validates_format_of       :email, :with => /^[-^!$#%&'*+\/=3D?`{|}~.\w]+@[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])*(\.[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])*)+$/x
  
  before_create :make_rss_code
  
  attr_protected :remember_token, :remember_token_expired_at, :activation_code, :salt, :crypted_password, :twitter_token, :twitter_secret
  
  # Virtual attribute for the unencrypted password
  attr_accessor :password
  
  def new_user_signedup
    ActivityUserNew.create(:user => self)    
    resend_activation if self.has_email? and self.is_pending?
  end  
  
  # docs: http://www.vaporbase.com/postings/stateful_authentication
  acts_as_state_machine :initial => :pending, :column => :status
  
  state :passive
  state :pending, :enter => :do_pending
  state :active, :enter => :do_activate
  state :suspended, :enter => :do_suspension
  state :probation, :enter => :do_probation
  state :deleted, :enter => :do_delete  
  
  event :register do
    transitions :from => :passive, :to => :pending
  end
  
  event :activate do
    transitions :from => [:pending, :passive], :to => :active 
  end
  
  event :suspend do
    transitions :from => [:passive, :pending, :active, :probation], :to => :suspended
  end
  
  event :delete do
    transitions :from => [:passive, :pending, :active, :suspended, :probation], :to => :deleted
  end
  
  event :unsuspend do
    transitions :from => :suspended, :to => :active
  end
  
  event :probation do
    transitions :from => [:passive, :pending, :active], :to => :probation    
  end
  
  event :unprobation do
    transitions :from => :probation, :to => :active, :guard => Proc.new {|u| !u.activated_at.blank? }
    transitions :from => :probation, :to => :pending, :guard => Proc.new {|u| !u.activation_code.blank? }
    transitions :from => :probation, :to => :passive    
  end
  
  def do_pending
    self.probation_at = nil
    self.suspended_at = nil
    self.deleted_at = nil    
  end
  
  def do_activate
    @activated = true
    self.activated_at ||= Time.now.utc
    self.activation_code = nil
    self.probation_at = nil
    self.suspended_at = nil
    self.deleted_at = nil
    self.warnings_count = 0
  end  
  
  def do_delete
    self.deleted_at = Time.now
    for e in endorsements
      e.destroy
    end    
    for f in followings
      f.destroy
    end
    for f in followers
      f.destroy
    end 
    for c in received_capitals
      c.destroy
    end
    for c in sent_capitals
      c.destroy
    end
    for c in constituents
      c.destroy
    end
    self.facebook_uid = nil
  end
  
  def do_probation
    self.probation_at = Time.now
  end
  
  def do_suspension
    self.suspended_at = Time.now
  end  
  
  def resend_activation
    make_activation_code
    UserMailer.deliver_welcome(self)    
  end

  def send_welcome
    unless self.have_sent_welcome
      UserMailer.deliver_welcome(self)    
    end
  end
  
  def to_param
    "#{id}-#{login.parameterize_full}"
  end  
  
  cattr_reader :per_page
  @@per_page = 25  
  
  def request=(request)
    self.ip_address = request.remote_ip
    self.user_agent = request.env['HTTP_USER_AGENT']
    self.referrer = request.env['HTTP_REFERER']
  end  
  
  def is_subscribed=(value)
    if not value
      self.is_newsletter_subscribed = false
      self.is_comments_subscribed = false
      self.is_votes_subscribed = false
      self.is_point_changes_subscribed = false      
      self.is_followers_subscribed = false
      self.is_finished_subscribed = false      
      self.is_messages_subscribed = false
      self.is_votes_subscribed = false
      self.is_admin_subscribed = false
    else
      self.is_newsletter_subscribed = true
      self.is_comments_subscribed = true
      self.is_votes_subscribed = true     
      self.is_point_changes_subscribed = true
      self.is_followers_subscribed = true 
      self.is_finished_subscribed = true           
      self.is_messages_subscribed = true
      self.is_votes_subscribed = true
      self.is_admin_subscribed = true
    end
  end
  
  def to_param_link
    '<a href="http://' + Government.last.base_url + '/users/' + sender.to_param + '">' + sender.name + '</a>'  
  end
  
  def is_admin?
    self.is_admin
  end
  
  def most_recent_activity
    activities.active.by_recently_created.find(:all, :limit => 1)[0]
  end  
  memoize :most_recent_activity
  
  def recent_login?
    return false if loggedin_at.nil?
    loggedin_at > Time.now-30.days
  end    
  def revisions_count
    document_revisions_count+point_revisions_count-questions_count-documents_count 
  end
  memoize :revisions_count
  
  def remember_token?
    remember_token_expires_at && Time.now.utc < remember_token_expires_at 
  end
  
  # These create and unset the fields required for remembering users between browser closes
  def remember_me
    remember_me_for 4.weeks
  end
  
  def remember_me_for(time)
    remember_me_until time.from_now.utc
  end
  
  def remember_me_until(time)
    self.remember_token_expires_at = time
    self.remember_token            = encrypt("#{email}--#{remember_token_expires_at}")
    save_with_validation(false)
  end
  
  def forget_me
    self.remember_token_expires_at = nil
    self.remember_token            = nil
    save_with_validation(false)
  end
  
  def name
    return login
  end
  
  def real_name
    return login
  end
  
  def facebook_id
    self.facebook_uid
  end
  
  def is_new?
    created_at > Time.now-(86400*7)
  end
  
  def recently_activated?
    @activated
  end
  
  def active?
    # the existence of an activation code means they have not activated yet
    activation_code.nil?
  end
  
  def activated?
    active?
  end
  
  def is_active?
    ['pending','active'].include?(status)
  end
  
  def is_suspended?
    ['suspended'].include?(status)
  end
  
  def is_pending?
    status == 'pending'
  end  
  
  def has_picture?
    attribute_present?("picture_id") or attribute_present?("buddy_icon_file_name") 
  end
  
  def has_twitter?
    attribute_present?("twitter_token")
  end
  
  def has_website?
    attribute_present?("website")
  end
  
  def ignore(u)
    f = followings.find_by_other_user_id(u.id)
    return f if f and f.value == -1
    unfollow(u) if f and f.value == 1
    followings.create(:other_user => u, :value => -1)    
  end
  
  def unignore(u)
    f = followings.find_by_other_user_id_and_value(u.id,-1)
    f.destroy if f
  end
  
  def has_facebook?
    self.attribute_present?("facebook_uid")
  end
  
  def has_email?
    self.attribute_present?("email")
  end  
  
  if TwitterAuth.oauth?
    include TwitterAuth::OauthUser
  else
    include TwitterAuth::BasicUser
  end
  
  def twitter
    if TwitterAuth.oauth?
      TwitterAuth::Dispatcher::Oauth.new(self)
    else
      TwitterAuth::Dispatcher::Basic.new(self)
    end
  end
  
  def twitter_followers_count
    return 0 unless attribute_present?("twitter_token")
    twitter.get('/users/'+twitter_id.to_s)['followers_count']
  end  
  
  def follow_twitter_friends
    count = 0
    friend_ids = twitter.get('/friends/ids.json?id='+twitter_id.to_s)
    if friend_ids.any?
      if following_user_ids.any?
        users = User.active.find(:all, :conditions => ["twitter_id in (?) and id not in (?)",friend_ids, following_user_ids])
      else
        users = User.active.find(:all, :conditions => ["twitter_id in (?)",friend_ids])
      end
      for user in users
        count += 1
        follow(user)
      end
    end
    return count
  end  
  
  # this is for when someone adds twitter to their account for the first time
  # it will look up all the people who are following this person on twitter and are already members
  # and automatically follow this new person here.
  def twitter_followers_follow
    count = 0
    followers_ids = twitter.get('/followers/ids.json?id='+twitter_id.to_s)
    if follower_ids.any?
      if follower_user_ids.any?
        users = User.active.find(:all, :conditions => ["twitter_id in (?) and id not in (?)",follower_ids, follower_user_ids])
      else
        users = User.active.find(:all, :conditions => ["twitter_id in (?)",follower_ids])
      end
      for user in users
        count += 1
        user.follow(self)
      end
    end
    return count    
  end
  
  def self.authenticate_from_rsk(token,request)
    begin
      soap_url = "https://egov.webservice.is/sst/runtime.asvc/com.actional.soapstation.eGOVDKM_AuthConsumer.AccessPoint?WSDL"
      soap = SOAP::WSDLDriverFactory.new(soap_url).create_rpc_driver
      soap.options["protocol.http.basic_auth"] << [soap_url,DB_CONFIG[RAILS_ENV]['rsk_soap_username'],DB_CONFIG[RAILS_ENV]['rsk_soap_password']]
      response = soap.generateSAMLFromToken(token,:token => token, :ipAddress=>request.remote_ip)
      
      if response and response[0] and response[0].message="Success"
        elements = Nokogiri.parse(response[1])
        name = elements.root.xpath("//blarg:NameIdentifier", {'blarg' => 'urn:oasis:names:tc:SAML:1.0:assertion'}).first.text
        national_identity = elements.root.xpath("//blarg:Attribute[@AttributeName='SSN']", {'blarg' => 'urn:oasis:names:tc:SAML:1.0:assertion'}).text
      else
        raise "Message was not a success #{response.inspect}"
      end
      
      u = User.find_by_national_identity(national_identity)
      unless u
        u = User.new(
         :login => name,
         :national_identity=>national_identity,
         :request => request
        )
        if u.save(false)
          u.activate!
        else
          raise "User could not be saved"
        end
      end
      RAILS_DEFAULT_LOGGER.info("RSK Login successful for #{u.inspect} #{response.inspect}")
      return u
    rescue  => ex
      RAILS_DEFAULT_LOGGER.error(ex.to_s+"\n\n"+ex.backtrace.to_s)
      return nil
    end
  end
  
  def send_report_if_needed!
    if self.reports_enabled
      if self.reports_interval and self.reports_interval==1
        interval = 1.hour
      elsif self.reports_interval and self.reports_interval==2
        interval = 1.day
      else
        interval = 7.days
      end
      if Time.now-interval>self.last_sent_report
        tags = TagSubscription.find_all_by_user_id(self.id).collect {|sub| sub.tag.name if sub.tag }.compact
        unless tags.empty?
          if self.reports_discussions
            priorities = Priority.tagged_with(tags,:match_any=>true).published.since(self.last_sent_report)
          else
            priorities = []
          end
          if self.reports_questions
            questions = Question.tagged_with(tags,:match_any=>true).published.since(self.last_sent_report)
          else
            questions = []
          end
          if self.reports_documents
            documents = Document.tagged_with(tags,:match_any=>true).published.since(self.last_sent_report)
          else
            documents = []
          end
          if self.reports_treaty_documents
            treaty_documents = TreatyDocument.tagged_with(tags,:match_any=>true).since(self.last_sent_report)
          else
            treaty_documents = []
          end
          if not treaty_documents.empty? or not documents.empty? or not questions.empty? or not priorities.empty?
            UserMailer.deliver_report(self,priorities,questions,documents,treaty_documents)
          end
        end
        self.reload
        self.last_sent_report=Time.now
        self.save(false)
      end
    end
  end

def update_with_facebook(facebook_user_id)
  self.facebook_uid = facebook_user_id
  # need to do some checking on whether this facebook_uid is already attached to a diff account
  User.active.find(:all, :conditions => ["facebook_uid = ? and id <> ?",self.facebook_uid,self.id]).each do |e|
    e.remove_facebook
    e.save_with_validation(false)
  end
  self.save_with_validation(false)
  return true
end

def remove_facebook
  self.facebook_uid = nil
end  

def make_rss_code
  return self.rss_code if self.attribute_present?("rss_code")
  self.rss_code = Digest::SHA1.hexdigest( Time.now.to_s.split(//).sort_by {rand}.join )
end  

def root_url
  return 'http://' + Government.last.base_url + '/'
end

def profile_url
    'http://' + Government.last.base_url + '/users/' + to_param
end

def unsubscribe_url
    'http://' + Government.last.base_url + '/unsubscribes/new'
end

def self.adapter
  return @adapter if @adapter
  config = Rails::Configuration.new
  @adapter = config.database_configuration[RAILS_ENV]["adapter"]
  return @adapter
end

def do_abusive!(parent_notifications)
   if self.warnings_count == 0 # this is their first warning, get a warning message
    parent_notifications << NotificationWarning1.new(:recipient => self)
  elsif self.warnings_count == 1 # 2nd warning
    parent_notifications << NotificationWarning2.new(:recipient => self)
  elsif self.warnings_count == 2 # third warning, on probation
    parent_notifications << NotificationWarning3.new(:recipient => self)      
    self.probation!
  elsif self.warnings_count > 3 # fourth or more warning, suspended
    self.suspend!
  end
  self.increment!("warnings_count")
end

protected

end
