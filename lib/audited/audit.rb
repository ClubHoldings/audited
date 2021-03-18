require 'set'

module Audited
  # Audit saves the changes to ActiveRecord models.  It has the following attributes:
  #
  # * <tt>auditable</tt>: the ActiveRecord model that was changed
  # * <tt>user</tt>: the user that performed the change; a string or an ActiveRecord model
  # * <tt>action</tt>: one of create, update, or delete
  # * <tt>audited_changes</tt>: a hash of all the changes
  # * <tt>comment</tt>: a comment set with the audit
  # * <tt>version</tt>: the version of the model
  # * <tt>request_uuid</tt>: a uuid based that allows audits from the same controller request
  # * <tt>created_at</tt>: Time that the change was performed
  #
  # This version of the Audit model is specific to Club Holdings, to match the legacy version of the table that is in use. Make sure this file is kept up to date with changes in the sunshine version.

  class YAMLIfTextColumnType
    class << self
      def load(obj)
        if Audited.audit_class.columns_hash["change_history"].type.to_s == "text"
          ActiveRecord::Coders::YAMLColumn.new(Object).load(obj)
        else
          obj
        end
      end

      def dump(obj)
        if Audited.audit_class.columns_hash["change_history"].type.to_s == "text"
          ActiveRecord::Coders::YAMLColumn.new(Object).dump(obj)
        else
          obj
        end
      end
    end
  end

  class Audit < ::ActiveRecord::Base
    # make this Audit model work without all the new columns that the Audit gem is trying to populate
    attr_accessor :associated_id, :associated_type, :user_id, :comment, :remote_address, :request_uuid

    belongs_to :auditable,  polymorphic: true
    # belongs_to :user,       polymorphic: true
    # belongs_to :associated, polymorphic: true
    belongs_to :membership,    :foreign_key => "membership_uid"
    belongs_to :quintess_user, :class_name => "QuintessUser", :foreign_key => "quintess_editor_uid"
    belongs_to :member,        :class_name => "Member", :foreign_key => "member_editor_uid" # This association screws up the quintess_user association somehow.
    belongs_to :membership_contract, :class_name => "MembershipContract", :foreign_key => "membership_contract_uid"

    before_create :set_version_number, :set_audit_user, :set_request_uuid, :set_remote_address

    cattr_accessor :audited_class_names
    self.audited_class_names = Set.new

    serialize :change_history, YAMLIfTextColumnType
    before_save :cancel_if_disabled
    before_save :fill_legacy_columns
    before_save(:fill_quintess_columns)

    Rails.version >= "3.2.0" ? (self.table_name = "Audit")      : set_table_name('Audit')
    Rails.version >= "3.2.0" ? (self.primary_key = "audit_uid") : set_primary_key('audit_uid')

    def user=(user_name)
    end

    def user
      nil
    end

    scope :ascending,     ->{ reorder(version: :asc) }
    scope :descending,    ->{ reorder(version: :desc)}
    scope :creates,       ->{ where(action: 'create')}
    scope :updates,       ->{ where(action: 'update')}
    scope :destroys,      ->{ where(action: 'destroy')}

    scope :up_until,      ->(date_or_time){ where("created_at <= ?", date_or_time) }
    scope :from_version,  ->(version){ where('version >= ?', version) }
    scope :to_version,    ->(version){ where('version <= ?', version) }
    scope :auditable_finder, ->(auditable_id, auditable_type){ where(auditable_id: auditable_id, auditable_type: auditable_type)}

    # redirect changes into the Quintess column
    def audited_changes=(changes)
      self.change_history = changes
    end

    def audited_changes
      change_history
    end

    # Return all audits older than the current one.
    def ancestors
      self.class.ascending.auditable_finder(auditable_id, auditable_type).to_version(version)
    end

    # Return an instance of what the object looked like at this revision. If
    # the object has been destroyed, this will be a new record.
    def revision
      clazz = auditable_type.constantize
      (clazz.find_by_id(auditable_id) || clazz.new).tap do |m|
        self.class.assign_revision_attributes(m, self.class.reconstruct_attributes(ancestors).merge(audit_version: version))
      end
    end

    # Returns a hash of the changed attributes with the new values
    def new_attributes
      (audited_changes || {}).inject({}.with_indifferent_access) do |attrs, (attr, values)|
        attrs[attr] = values.is_a?(Array) ? values.last : values
        attrs
      end
    end

    # Returns a hash of the changed attributes with the old values
    def old_attributes
      (audited_changes || {}).inject({}.with_indifferent_access) do |attrs, (attr, values)|
        attrs[attr] = Array(values).first

        attrs
      end
    end

    # Allows user to undo changes
    def undo
      case action
      when 'create'
        # destroys a newly created record
        auditable.destroy!
      when 'destroy'
        # creates a new record with the destroyed record attributes
        auditable_type.constantize.create!(audited_changes)
      when 'update'
        # changes back attributes
        auditable.update!(audited_changes.transform_values(&:first))
      else
        raise StandardError, "invalid action given #{action}"
      end
    end

    # Allows user to be set to either a string or an ActiveRecord object
    # @private
    # def user_as_string=(user)
    #   # reset both either way
    #   self.user_as_model = self.username = nil
    #   user.is_a?(::ActiveRecord::Base) ?
    #     self.user_as_model = user :
    #     self.username = user
    # end
    # alias_method :user_as_model=, :user=
    # alias_method :user=, :user_as_string=
    #
    # # @private
    # def user_as_string
    #   user_as_model || username
    # end
    # alias_method :user_as_model, :user
    # alias_method :user, :user_as_string

    # Returns the list of classes that are being audited
    def self.audited_classes
      audited_class_names.map(&:constantize)
    end

    # All audits made during the block called will be recorded as made
    # by +user+. This method is hopefully threadsafe, making it ideal
    # for background operations that require audit information.

    # ClubHoldings version had this commented out
    def self.as_user(user)
      last_audited_user = ::Audited.store[:audited_user]
      ::Audited.store[:audited_user] = user
      yield
    ensure
      ::Audited.store[:audited_user] = last_audited_user
    end

    # @private
    def self.reconstruct_attributes(audits)
      audits.each_with_object({}) do |audit, all|
        all.merge!(audit.new_attributes)
        all[:audit_version] = audit.version
     end
    end

    # @private
    def self.assign_revision_attributes(record, attributes)
      attributes.each do |attr, val|
        record = record.dup if record.frozen?

        if record.respond_to?("#{attr}=")
          record.attributes.key?(attr.to_s) ?
            record[attr] = val :
            record.send("#{attr}=", val)
        end
      end
      record
    end

    # use created_at as timestamp cache key
    def self.collection_cache_key(collection = all, *)
      super(collection, :created_at)
    end

    private

    def set_version_number
      # max = self.class.auditable_finder(auditable_id, auditable_type).maximum(:version) || 0
      # self.version = max + 1
      # we'll try it without versioning first.
      self.version = 0
    end

    def self.these_uids(key_uid_hash = nil)
      #logger.error "Threading Audit.these_uids, key_uid_hash = #{key_uid_hash.inspect rescue 'rescue'}"

      @@foreign_keys = key_uid_hash || {}
    end

    def self.uids_columns()
      begin
        #logger.error "Threading Audit.uids_columns, @@foreign_keys = #{@@foreign_keys.inspect rescue 'rescue'}"
        logger.error("Threading Audit.uids_columns, member/membership mismatch @@foreign_keys = #{(@@foreign_keys && @@foreign_keys.inspect) rescue 'rescue'}") if @@foreign_keys && @@foreign_keys[:member_uid] && @@foreign_keys[:membership_uid] && MemberMembership.find(:first, :conditions => ['member_uid = ? AND membership_uid = ?', @@foreign_keys[:member_uid], @@foreign_keys[:membership_uid]])
      rescue
      end

      @@foreign_keys rescue @@foreign_keys = {}
    end

    def self.audited_classes
      @@audited_classes ||= find( :all, :select => "DISTINCT auditable_type", :order  => "auditable_type ASC" ).collect {|a| a.auditable_type}
    end

    def self.add_audited_class(class_name)
      unless audited_classes.detect{|ac| ac == class_name}
        audited_classes << class_name
      end
    end

    def self.disabled=(disabled_flag)
      @@disabled = disabled_flag
    end

    def self.disabled
      # if action == 'create'
      #   self.version = 1
      # else
      #   max = self.class.auditable_finder(auditable_id, auditable_type).maximum(:version) || 0
      #   self.version = max + 1
      # end

      # we'll try it without versioning first.
      # self.version = 0
      @@disabled rescue @@disabled = false
    end

    def set_audit_user
      self.user ||= ::Audited.store[:audited_user] # from .as_user
      self.user ||= ::Audited.store[:current_user].try!(:call) # from Sweeper
      # nil # prevent stopping callback chains
    end

    def set_request_uuid
      if self.respond_to?(:request_uuid)
        self.request_uuid ||= ::Audited.store[:current_request_uuid]
        self.request_uuid ||= SecureRandom.uuid
      end
    end

    def set_remote_address
      self.remote_address ||= ::Audited.store[:current_remote_address]
    end

  protected
    def fill_legacy_columns
      atu = (self.action || 'nothing').upcase
      self.audit_type_ucode = atu if %w{CREATE UPDATE DESTROY}.include?(atu)
      true
    end

  if Rails.version >= "3.2.0"
    def fill_quintess_columns
      self.member_editor_uid   = Logon.current_member,
      self.quintess_editor_uid = Logon.current_quintess_user
      true
    end

    def cancel_if_disabled
      return false if Audit.disabled
      true
    end
  end # if Rails.version

  end
end
