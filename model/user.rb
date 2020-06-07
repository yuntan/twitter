# -*- coding: utf-8 -*-

require 'lib/weakstorage'
require 'skin'

require 'typed-array'

class Plugin::Twitter::User < Diva::Model
  extend Gem::Deprecate
  extend Memoist

  include Diva::Model::Identity
  include Diva::Model::UserMixin

  register :twitter_user, name: "Twitter User"

  # args format
  # key     | value
  # --------+-----------
  # id      | user id
  # idname  | account name
  # nickname| account usual name
  # location| location(not required)
  # detail  | detail
  # profile_image_url | icon

  field.int    :id
  field.string :idname
  field.string :name
  field.string :location
  field.string :detail
  field.string :profile_image_url
  field.string :url
  field.bool   :protected
  field.bool   :verified
  field.int    :followers_count
  field.int    :statuses_count
  field.int    :friends_count

  handle %r[\Ahttps?://twitter.com/[a-zA-Z0-9_]+/?\Z] do |uri|
    match = %r[\Ahttps?://twitter.com/(?<screen_name>[a-zA-Z0-9_]+)/?\Z].match(uri.to_s)
    notice match.inspect
    if match
      user = findbyidname(match[:screen_name], Diva::DataSource::USE_LOCAL_ONLY)
      if user
        user
      else
        Thread.new do
          findbyidname(match[:screen_name], Diva::DataSource::USE_ALL)
        end
      end
    else
      raise Diva::DivaError, "id##{match[:screen_name]} does not exist in #{self}."
    end
  end

  def self.system
    Mikutter::System::User.system end

  def self.memory
    @memory ||= UserMemory.new end

  alias :to_i :id
  deprecate :to_i, "id", 2017, 05

  def idname
    self[:idname] end
  alias to_s idname

  def title
    "#{idname}(#{name})"
  end

  def protected?
    !!self[:protected]
  end

  def verified?
    !!self[:verified]
  end

  def icon
    @icon ||=
      begin
        photo = Diva::Model(:photo)&.
                  generate(
                    [{ policy: :original,
                       photo: profile_image_url.gsub(/_normal(.[a-zA-Z0-9]+)\Z/, '\1')},
                     { name: :mini,
                       width: 24, height: 24,
                       policy: :fit,
                       photo: profile_image_url.gsub(/_normal(.[a-zA-Z0-9]+)\Z/, '_mini\1')},
                     { name: :normal,
                       width: 48, height: 48,
                       policy: :fit,
                       photo: profile_image_url},
                     { name: :bigger,
                       width: 73, height: 73,
                       policy: :fit,
                       photo: profile_image_url.gsub(/_normal(.[a-zA-Z0-9]+)\Z/, '_bigger\1')} ],
                    perma_link: profile_image_url)
        photo ||= Enumerator.new{|y| Plugin.filtering(:photo_filter, profile_image_url, y) }.first
        photo || Skin[:notfound]
      end
    Plugin.filtering(:miracle_icon_filter, @icon)[0]
  end
  alias_method :icon_large, :icon

  # 大きいサイズのアイコンのURLを返す
  # ==== Return
  # 元のサイズのアイコンのURL
  def profile_image_url_large
    url = self[:profile_image_url]
    if url
      url.gsub(/_normal(.[a-zA-Z0-9]+)\Z/, '\1') end end

  def follow
    if(@value[:post]) then
      @value[:post].follow(self)
    end
  end

  def inspect
    "TwitterUser(@#{@value[:idname]})"
  end

  # 投稿がシステムユーザだった場合にtrueを返す
  def system?
    false end

  def self.findbyidname(idname, count=Diva::DataSource::USE_ALL)
    memory.findbyidname(idname, count) end

  def self.store_datum(datum)
    return datum if datum[:id][0] == '+'[0]
    super
  end

  def ==(other)
    if other.is_a?(String) then
      @value[:idname] == other
    elsif other.is_a?(User) then
      other[:id] == self[:id] end end

  # このUserオブジェクトが、登録されているアカウントのうちいずれかのものであるなら true を返す
  def me?(world = Enumerator.new{|y| Plugin.filtering(:worlds, y) })
    case world
    when Enumerable
      world.any?(&method(:me?))
    when Diva::Model
      world.class.slug == :twitter && world.user_obj == self
    end
  end

  # 互換性のため
  alias is_me? me?
  deprecate :is_me?, "me?", 2017, 05

  # :nodoc:
  def count_favorite_by
    Thread.new {raise RuntimeError, 'Favstar is dead.'} end
  deprecate :count_favorite_by, :none, 2017, 05


  # ユーザが今までにお気に入りにしたメッセージ数の概算を返す
  def count_favorite_given
    @value[:favourites_count] end

  memoize def perma_link
    Diva::URI.new("https://twitter.com/#{idname}")
  end

  alias to_user user

  class UserMemory < Diva::Model::Memory
    def initialize
      super(Plugin::Twitter::User)
      @idnames = {}             # idname => User
    end

    def findbyid(id, policy)
      result = super
      if !result and policy == Diva::DataSource::USE_ALL
        if id.is_a? Enumerable
          id.each_slice(100).map{|id_list|
            Service.primary.twitter.user_lookup(id: id_list.join(','.freeze)) || [] }.flatten
        else
          Service.primary.twitter.user_show(id: id) end
      else
        result end end

    def findbyidname(idname, policy)
      if @idnames[idname.to_s]
        @idnames[idname.to_s]
      elsif policy == Diva::DataSource::USE_ALL
        Service.primary.user_show(screen_name: idname)
      end
    end

    def store_datum(user)
      @idnames[user.idname.to_s] = user
      super
    end
  end

end

class Users < TypedArray(Plugin::Twitter::User)
end

User = Plugin::Twitter::User
