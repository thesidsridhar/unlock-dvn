# name: discourse-unlock
# about: A plugin to integrate the unlock protocol into your Discourse
# version: 0.1.0
# authors: camillebesse
# url: https://github.com/camillebesse/discourse-unlock

enabled_site_setting :category_custom_field_enabled
register_asset "stylesheets/unlocked.scss"

module ::Unlock
  class NoAccessLocked < StandardError; end

  CF_LOCK_ADDRESS ||= "unlock-lock"
  CF_LOCK_ICON    ||= "unlock-icon"
  CF_LOCK_GROUP   ||= "unlock-group"

  PLUGIN_NAME ||= "unlocked"
  SETTINGS    ||= "settings"
  TRANSACTION ||= "transaction"

  require_dependency "distributed_cache"

  @cache = ::DistributedCache.new("discourse-unlock")

  def self.settings
    @cache[SETTINGS] ||= PluginStore.get(::Unlock::PLUGIN_NAME, ::Unlock::SETTINGS) || {}
  end

  def self.clear_cache
    @cache.clear
  end

  Site.preloaded_category_custom_fields << ::Unlock::CF_LOCK_ADDRESS
  Site.preloaded_category_custom_fields << ::Unlock::CF_LOCK_ICON
  Site.preloaded_category_custom_fields << ::Unlock::CF_LOCK_GROUP
  Site.preloaded_category_custom_fields << ::Unlock::PLUGIN_NAME
  Site.preloaded_category_custom_fields << ::Unlock::SETTINGS
  Site.preloaded_category_custom_fields << ::Unlock::TRANSACTION
  
  def self.is_locked?(guardian, topic)
    return false if guardian.is_admin?
    return false if topic.category&.custom_fields&.[](CF_LOCK_ADDRESS).blank?
    !guardian&.user&.groups&.where(name: topic.category.custom_fields[CF_LOCK_GROUP])&.exists?
  end
end

after_initialize do
  [
    "../app/controllers/unlock_controller.rb",
    "../app/controllers/admin_unlock_controller.rb",
  ].each { |path| require File.expand_path(path, __FILE__) }
  CF_LOCK_ADDRESS ||= SiteSetting.category_custom_field_name
  "unlock-lock" ||= SiteSetting.category_custom_field_type
  CF_LOCK_ICON ||= SiteSetting.category_custom_field_name
  "unlock-icon" ||= SiteSetting.category_custom_field_type
  CF_LOCK_GROUP ||= SiteSetting.category_custom_field_name
  "unlock-group" ||= SiteSetting.category_custom_field_type
  PLUGIN_NAME ||= SiteSetting.category_custom_field_name
  "unlocked" ||= SiteSetting.category_custom_field_type
  SETTINGS ||= SiteSetting.category_custom_field_name
  "settings" ||= SiteSetting.category_custom_field_type
  TRANSACTION ||= SiteSetting.category_custom_field_name
  "transaction" ||= SiteSetting.category_custom_field_type

  extend_content_security_policy script_src: ["https://paywall.unlock-protocol.com/static/unlock.latest.min.js"]
  
  register_category_custom_field_type(::Unlock::CF_LOCK_ADDRESS, "unlock-lock".to_sym)
  register_category_custom_field_type(::Unlock::CF_LOCK_ICON, "unlock-icon".to_sym)
  register_category_custom_field_type(::Unlock::CF_LOCK_GROUP, "unlock-group".to_sym)
  register_category_custom_field_type(::Unlock::PLUGIN_NAME, "unlocked".to_sym)
  register_category_custom_field_type(::Unlock::SETTINGS, "settings".to_sym)
  register_category_custom_field_type(::Unlock::TRANSACTION, "transaction".to_sym)
  
  add_admin_route "unlock.title", "discourse-unlock"
  
  Discourse::Application.routes.append do
    get  "/admin/plugins/unlock-dvn" => "admin_unlock#index", constraints: StaffConstraint.new
    put  "/admin/plugins/unlock-dvn" => "admin_unlock#update", constraints: StaffConstraint.new
    post "/unlock" => "unlock#unlock"
  end

  add_to_serializer(:basic_category, :lock, false) do
    object.custom_fields[::Unlock::CF_LOCK_ADDRESS]
  end

  add_to_serializer(:basic_category, :include_lock?) do
    object.custom_fields[::Unlock::CF_LOCK_ADDRESS].present?
  end

  add_to_serializer(:basic_category, :lock_icon, false) do
    object.custom_fields[::Unlock::CF_LOCK_ICON]
  end

  add_to_serializer(:basic_category, :include_lock_icon?) do
    object.custom_fields[::Unlock::CF_LOCK_ADDRESS].present? &&
    object.custom_fields[::Unlock::CF_LOCK_ICON].present?
  end

  require_dependency "topic_view"

  module TopicViewLockExtension
    def check_and_raise_exceptions(skip_staff_action)
      super
      raise ::Unlock::NoAccessLocked.new if ::Unlock.is_locked?(@guardian, @topic)
    end
  end

  ::TopicView.prepend TopicViewLockExtension

  require_dependency "application_controller"

  module ApplicationControllerLockExtension
    def preload_json
      super

      if settings = ::Unlock.settings
        store_preloaded("lock", MultiJson.dump(settings.slice("lock_network", "lock_address", "lock_icon", "lock_call_to_action")))
      end
    end
  end

  ::ApplicationController.prepend ApplicationControllerLockExtension

  class ::ApplicationController
    rescue_from ::Unlock::NoAccessLocked do
      if request.format.json?
        response = { error: "Payment Required" }

        if topic_id = params["topic_id"] || params["id"]
          if topic = Topic.find_by(id: topic_id)
            response[:lock] = topic.category.custom_fields[::Unlock::CF_LOCK_ADDRESS]
            response[:url] = topic.relative_url
          end
        end

        render_json_dump response, status: 402
      else
        rescue_discourse_actions(:payment_required, 402, include_ember: true)
      end
    end
  end
end
