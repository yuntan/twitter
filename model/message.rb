# -*- coding:utf-8 -*-

require 'lib/timelimitedqueue'
require_relative 'user'

require 'delegate'
require 'net/http'
require 'typed-array'

=begin
= Message
投稿１つを表すクラス。
=end
class Plugin::Twitter::Message < Diva::Model
  extend Memoist

  PermalinkMatcher = Regexp.union(
    %r[\Ahttps?://(?:mobile\.)?twitter.com/(?:#!/)?(?<screen_name>[a-zA-Z0-9_]+)/status(?:es)?/(?<id>\d+)(?:\?.*)?\Z], # Twitter
    %r[\Ahttp://favstar\.fm/users/(?<screen_name>[a-zA-Z0-9_]+)/status/(?<id>\d+)], # Hey, Favstar. Ban stop me premiamu!
    %r[\Ahttp://aclog\.koba789\.com/i/(?<id>\d+)] # Hey, Twitter. Please BAN me rhenium!
  ).freeze
  MentionMatcher = /(?:@|＠|〄|☯|⑨|♨)([a-zA-Z0-9_]+)/.freeze
  DESCRIPTION_UNESCAPE_RULE = {'&gt;' => '>', '&lt;' => '<', '&amp;' => '&'}.to_proc
  DESCRIPTION_UNESCAPE_REGEXP = /&(?:gt|lt|amp);/.freeze

  extend Gem::Deprecate
  include Diva::Model::Identity

  register :twitter_tweet,
           name: "Tweet",
           timeline: true

  @@appear_queue = TimeLimitedQueue.new(65536, 0.1, Set){ |messages|
    Plugin.call(:appear, messages) }

  # args format
  # key     | value(class)
  #---------+--------------
  # id      | id of status(mixed)
  # entity  | entity(mixed)
  # message | posted text(String)
  # tags    | kind of message(Array)
  # user    | user who post this message(User or Hash or mixed(User IDNumber))
  # receiver| receive user(User)
  # replyto | source message(Message or mixed(Status ID))
  # retweet | retweet to this message(Message or StatusID)
  # post    | post object(Service)
  # image   | image(URL or Image object)

  field.int    :id, required: true
  field.string :message, required: true             # Message description
  field.has    :user, Plugin::Twitter::User, required: true # Send by user
  field.int    :in_reply_to_user_id                 # リプライ先ユーザID
  field.has    :receiver, Plugin::Twitter::User     # Send to user
  field.int    :in_reply_to_status_id               # リプライ先ツイートID
  # field.has    :replyto, Plugin::Twitter::Message   # Reply to this message
  field.has    :retweet, Plugin::Twitter::Message   # ReTweet to this message
  field.string :source                              # using client
  field.bool   :exact                               # true if complete data
  field.time   :created                             # posted time
  field.time   :modified                            # updated time
  field.int    :quote_count
  field.int    :reply_count
  field.int    :retweet_count
  field.int    :favorite_count
  field.int    :quoted_status_id

  handle PermalinkMatcher do |uri|
    match = PermalinkMatcher.match(uri.to_s)
    if match
      message = findbyid(match[:id].to_i, Diva::DataSource::USE_LOCAL_ONLY)
      if message
        message
      else
        Thread.new do
          findbyid(match[:id].to_i, Diva::DataSource::USE_ALL)
        end
      end
    else
      raise Diva::DivaError, "id##{match[:id]} does not exist in #{self}."
    end
  end

  # appearイベント
  def self.appear(message) # :nodoc:
    @@appear_queue.push(message)
  end

  def self.memory
    @memory ||= DataSource.new end

  # Message.newで新しいインスタンスを作らないこと。インスタンスはコアが必要に応じて作る。
  # 検索などをしたい場合は、 _Diva_ のメソッドを使うこと
  def initialize(value)
    type_strict value => Hash
    if not(value[:image].is_a?(Plugin::Twitter::Message::Image)) and value[:image]
      value[:image] = Plugin::Twitter::Message::Image.new(value[:image]) end
    super(value)
    # self[:replyto].add_child(self) if self[:replyto].is_a?(Plugin::Twitter::Message)
    self[:retweet].add_child(self) if self[:retweet].is_a?(Plugin::Twitter::Message)

    Plugin.call(:twitter_appear_tweets, [self])
  end

  # 投稿主のidnameを返す
  def idname
    user.idname
  end

  def icon
    user.icon
  end

  # この投稿へのリプライをつぶやく
  def post(other, &proc)
    other[:to] = [self]
    service = Service.primary
    service.post(other){|*a| yield(*a) if block_given? }
  end

  # リツイートする
  def retweet
    service = Service.primary
    if retweetable? and service
      service.retweet(self){|*a| yield(*a) if block_given? } end end
  deprecate :retweet, "spell (see: https://reference.mikutter.hachune.net/reference/2017/11/28/spell.html#share-twitter-tweet)", 2018, 11

  # この投稿を削除する
  def destroy
    service = Service.primary
    if deletable? and service
      service.destroy(self){|*a| yield(*a) if block_given? } end end
  deprecate :destroy, "spell (see: https://reference.mikutter.hachune.net/reference/2017/11/28/spell.html#destroy-twitter-tweet)", 2018, 12

  # お気に入り状態を変更する。_fav_ がtrueならお気に入りにし、falseならお気に入りから外す。
  def favorite(fav = true)
    service = Service.primary
    if favoritable? and service
      service.favorite(self, fav) end end

  # お気に入りから削除する
  def unfavorite
    favorite(false) end

  # この投稿のお気に入り状態を返す。お気に入り状態だった場合にtrueを返す
  def favorite?(user_or_world=Service.primary)
    return unless user_or_world
    case user_or_world.class.slug
    when :twitter_user
      favorited_by.include?(user_or_world)
    when :twitter
      favorited_by.include?(user_or_world.user_obj)
    end
  end

  # 投稿がシステムメッセージだった場合にtrueを返す
  def system?
    false
  end

  # この投稿にリプライする権限があればtrueを返す
  def repliable?(world=nil)
    world, = Plugin.filtering(:world_current, nil) unless world
    world.class.slug == :twitter if world
  end

  # この投稿をお気に入りに追加する権限があればtrueを返す
  def favoritable?(world=nil)
    world, = Plugin.filtering(:world_current, nil) unless world
    world.class.slug == :twitter if world
  end
  alias favoriable? favoritable?

  # この投稿をリツイートする権限があればtrueを返す
  def retweetable?(world=nil)
    world, = Plugin.filtering(:world_current, nil) unless world
    world.class.slug == :twitter and not protected? if world
  end

  # この投稿を削除する権限があればtrueを返す
  def deletable?
    from_me? end

  # この投稿の投稿主のアカウントの全権限を所有していればtrueを返す
  def from_me?(world = Enumerator.new{|y| Plugin.filtering(:worlds, y) })
    case world
    when Enumerable
      world.any?(&method(:from_me?))
    when Diva::Model
      world.class.slug == :twitter && world.user_obj == self.user
    end
  end

  # この投稿が自分宛ならばtrueを返す
  def to_me?(world = Enumerator.new{|y| Plugin.filtering(:worlds, y) })
    case world
    when Enumerable
      world.any?(&method(:to_me?))
    when Diva::Model
      world.class.slug == :twitter && receive_to?(world.user_obj)
    end
  end

  # この投稿が公開されているものならtrueを返す。少しでも公開範囲を限定しているならfalseを返す。
  def protected?
    if retweet?
      retweet_ancestor.protected?
    else
      user.protected? end end

  # この投稿が承認されているものならtrueを返す。
  def verified?
    user.verified? end

  # この投稿の投稿主を返す。messageについては、userが必ず付与されていることが保証されているので
  # Deferredを返さない
  def user
    self[:user] end

  def service
    warn "Message#service is obsolete method. use `Service.primary'."
    Service.primary end

  # この投稿を宛てられたユーザを返す
  def receiver
    if self[:receiver].is_a?(Plugin::Twitter::User)
      self[:receiver]
    elsif self[:receiver] and self[:in_reply_to_user_id]
      receiver_id = self[:in_reply_to_user_id]
      self[:receiver] = parallel{
        self[:receiver] = Plugin::Twitter::User.findbyid(receiver_id) }
    else
      match = MentionMatcher.match(self[:message].to_s)
      if match
        result = Plugin::Twitter::User.findbyidname(match[1])
        self[:receiver] = result if result end end end

  # ユーザ _other_ に宛てられたメッセージならtrueを返す。
  # _other_ は、 User か_other_[:id]と_other_[:idname]が呼び出し可能なもの。
  def receive_to?(other)
    type_strict other => :[]
    (self[:receiver] and other[:id] == self[:receiver].id) or receive_user_idnames.include? other[:idname] end

  # このツイートが宛てられたユーザを可能な限り推測して、その idname(screen_name) を配列で返す。
  # 例えばツイート本文内に「@a @b @c」などと書かれていたら、["a", "b", "c"]を返す。
  # ==== Return
  # 宛てられたユーザの idname(screen_name) の配列
  def receive_user_idnames
    self[:message].to_s.scan(MentionMatcher).map(&:first) end
  alias :receive_user_screen_names :receive_user_idnames
  deprecate :receive_user_screen_names, "receive_user_idnames", 2020, 7

  # 自分がこのMessageにリプライを返していればtrue
  def mentioned_by_me?
    children.any?{ |m| m.from_me? } end

  # このメッセージが何かしらの別のメッセージに宛てられたものなら真
  def has_receive_message?
    !!(self[:replyto] || self[:in_reply_to_status_id]) end
  alias reply? has_receive_message?

  # このメッセージが何かに対するリツイートなら真
  def retweet?
    !!self[:retweet] end

  # この投稿が別の投稿に宛てられたものならそれを返す。
  # _force_retrieve_ がtrueなら、呼び出し元のスレッドでサーバに問い合わせるので、
  # 親投稿を受信していなくてもこの時受信できるが、スレッドがブロッキングされる。
  # falseならサーバに問い合わせずに結果を返す。
  # Messageのインスタンスかnilを返す。
  def receive_message(force_retrieve=false)
    @in_reply_to_status or retweet_source(force_retrieve) end

  def receive_message_d(force_retrieve=false)
    Thread.new{ receive_message(force_retrieve) } end

  # このMessageの宛先になっているMessageを取得して返す。
  def in_reply_to_status_d
    Deferred.new do
      next unless in_reply_to_status_id
      # next replyto if replyto
      next @in_reply_to_status if defined? @in_reply_to_status

      twitter = Plugin.collect(:twitter_worlds).first.twitter
      @in_reply_to_status = +twitter.status_show(id: in_reply_to_status_id)
      @in_reply_to_status.add_child self
      @in_reply_to_status
    end
  end

  def replyto_source_d(_)
    in_reply_to_status_d
  end

  # このMessageがリツイートであるなら、リツイート元のツイートを返す。
  # リツイートではないならnilを返す。リツイートであるかどうかを確認するには、
  # このメソッドの代わりに Message#retweet? を使う。
  # ==== Args
  # [force_retrieve]
  # ==== Return
  # Message|nil リツイート元のMessage。リツイートではないならnil
  def retweet_parent(force_retrieve=false)
    if retweet?
      case self[:retweet]
      when Integer
        self[:retweet] = Message.findbyid(retweet, force_retrieve ? -1 : 1) || self[:retweet]
      when Plugin::Twitter::Message
        self[:retweet].add_child(self) unless self[:retweet].retweeted_statuses.include?(self)
      end
      self[:retweet]
    end
  end

  # retweet_parent の戻り値をnextに渡すDeferredableを返す
  # ==== Args
  # [force_retrieve] 真なら、ツイートがメモリ上に見つからなかった場合Twitter APIリクエストを発行する
  # ==== Return
  # Deferredable nextの引数にリプライ元のMessageを渡す。リツイートではない場合は失敗し、trap{}にnilを渡す
  def retweet_parent_d(force_retrieve=true)
    promise = Delayer::Deferred.new(true)
    Thread.new do
      begin
        result = retweet_source(force_retrieve)
        if result.is_a?(Plugin::Twitter::Message)
          promise.call(result)
        else
          promise.fail(result)
        end
      rescue Exception => err
        promise.fail(err)
      end
    end
    promise
  end

  # このMessageが引用した投稿を返す。
  def quoted_status_d
    Deferred.new do
      next unless quoted_status_id
      next @quoted_status if defined? @quoted_status

      twitter = Plugin.collect(:twitter_worlds).first.twitter
      @quoted_status = +twitter.status_show(id: quoted_status_id)
      # @quoted_status&.add_quoted_by self
      @quoted_status
    end
  end

  # self が、何らかのツイートを引用しているなら真を返す
  # ==== Return
  # TrueClass|FalseClass
  def quoting?
    !!quoted_status_id
  end

  # selfを引用している _Diva::Model_ を登録する
  # ==== Args
  # [message] Diva::Model selfを引用しているModel
  # ==== Return
  # self
  def add_quoted_by(message)
    atomic do
      @quoted_by ||= Diva::Model.container_class.new
      unless @quoted_by.include? message
        if @quoted_by.frozen?
          @quoted_by = Diva::Model.container_class.new(@quoted_by + [message])
        else
          @quoted_by << message end end
      self end end

  # selfを引用しているDivaを返す
  # ==== Return
  # Diva::Model.container_class selfを引用しているDiva::Modelの配列
  def quoted_by
    if defined? @quoted_by
      @quoted_by
    else
      atomic do
        @quoted_by ||= Diva::Model.container_class.new end end.freeze end

  # self が、何らかのツイートから引用されているなら真を返す
  # ==== Return
  # TrueClass|FalseClass
  def quoted_by?
    !quoted_by.empty? end

  # 投稿の宛先になっている投稿を再帰的にさかのぼるような _Enumerator_ を返す。
  # ==== Return
  # Enumerator
  def ancestors_enumerator(force_retrieve=false)
    Enumerator.new do |yielder|
      message = self
      while message
        yielder << message
        message = message.receive_message(force_retrieve) end end end
  private :ancestors_enumerator

  # 投稿の宛先になっている投稿を再帰的にさかのぼり、それぞれを引数に取って
  # ブロックが呼ばれる。
  # ブロックが渡されていない場合、 _Enumerator_ を返す。
  # _force_retrieve_ は、 Message#receive_message の引数にそのまま渡される
  # ==== Return
  # obj|Enumerator
  def each_ancestor(force_retrieve=false, &proc)
    e = ancestors_enumerator(force_retrieve)
    if block_given?
      e.each(&proc)
    else
      e end end
  alias :each_ancestors :each_ancestor
  deprecate :each_ancestors, "each_ancestor", 2016, 12

  # 投稿の宛先になっている投稿を再帰的にさかのぼり、それらを配列にして返す。
  # 配列インデックスが大きいものほど、早く投稿された投稿になる。
  # （[0]は[1]へのリプライ）
  def ancestors(force_retrieve=false)
    ancestors_enumerator(force_retrieve).to_a end

  # 投稿の宛先になっている投稿を再帰的にさかのぼり、何にも宛てられていない投稿を返す。
  # つまり、一番祖先を返す。
  def ancestor(force_retrieve=false)
    ancestors(force_retrieve).last end

  # retweet元を再帰的にさかのぼるような _Enumerator_ を返す。
  # この _Enumerator_ は最初にこの _Message_ 自身を yield し、以降は直前に yield した
  # 要素のretweet元を yield する。
  # ==== Return
  # Enumerator
  def retweet_ancestors_enumerator(force_retrieve=false)
    Enumerator.new do |yielder|
      message = self
      while message
        yielder << message
        message = message.retweet_parent(force_retrieve)
      end end end
  private :retweet_ancestors_enumerator

  # retweet元を再帰的にさかのぼり、それぞれを引数に取って
  # ブロックが呼ばれる。
  # ブロックが渡されていない場合、 _Enumerator_ を返す。
  # _force_retrieve_ は、 Message#retweet_parent の引数にそのまま渡される
  # ==== Return
  # obj|Enumerator
  def each_retweet_ancestor(force_retrieve=false, &proc)
    e = retweet_ancestors_enumerator(force_retrieve)
    if block_given?
      e.each(&proc)
    else
      e end end
  alias :each_retweet_ancestors :each_retweet_ancestor
  deprecate :each_retweet_ancestors, "each_retweet_ancestor", 2016, 12

  # retweet元を再帰的に遡り、それらを配列にして返す。
  # 配列の最初の要素は必ずselfになり、以降は直前の要素のリツイート元となる。
  # ([0]は[1]へのリツイート)
  # ==== Return
  # Enumerator
  def retweet_ancestors(force_retrieve=false)
    retweet_ancestors_enumerator(force_retrieve).to_a end

  # リツイート元を再帰的に遡り、リツイートではないツイートを返す。
  # selfがリツイートでない場合は、selfを返す。
  # ==== Args
  # [force_retrieve] 真なら、ツイートがメモリ上に見つからなかった場合Twitter APIリクエストを発行する
  # ==== Return
  # Message
  def retweet_ancestor(force_retrieve=false)
    retweet_ancestors(force_retrieve).last end

  # このMessageがリツイートなら、何のリツイートであるかを返す。
  # 返される値の retweet? は常に false になる
  # ==== Args
  # [force_retrieve] 真なら、ツイートがメモリ上に見つからなかった場合Twitter APIリクエストを発行する
  # ==== Return
  # Message|nil リツイートであればリツイート元のMessage、リツイートでなければnil
  def retweet_source(force_retrieve=false)
    if retweet?
      retweet_ancestor(force_retrieve) end end

  # retweet_source の戻り値をnextに渡すDeferredableを返す
  # ==== Args
  # [force_retrieve] 真なら、ツイートがメモリ上に見つからなかった場合Twitter APIリクエストを発行する
  # ==== Return
  # Deferredable nextの引数にリプライ元のMessageを渡す。リツイートではない場合は失敗し、trap{}にnilを渡す
  def retweet_source_d(force_retrieve=true)
    promise = Delayer::Deferred.new(true)
    Thread.new do
      begin
        result = retweet_source(force_retrieve)
        if result.is_a?(Plugin::Twitter::Message)
          promise.call(result)
        else
          promise.fail(result)
        end
      rescue Exception => err
        promise.fail(err)
      end
    end
    promise
  end

  # このMessageが属する親子ツリーに属する全てのMessageを含むSetを返す
  # ==== Args
  # [force_retrieve] 外部サーバに問い合わせる場合真
  # ==== Return
  # 関係する全てのツイート(Set)
  def around(force_retrieve = false)
    ancestor(force_retrieve).children_all end

  # この投稿に宛てられた投稿をSetオブジェクトにまとめて返す。
  def children
    @children ||= Plugin.filtering(:replied_by, self, Set.new(retweeted_statuses))[1] end

  # childrenを再帰的に遡り全てのMessageを返す
  # ==== Return
  # このMessageの子全てをSetにまとめたもの
  def children_all
    children.inject(Diva::Model.container_class.new([self])){ |result, item| result.concat item.children_all } end

  def favorited_by_d
    arr = Plugin.filtering(:favorited_by, self, [])[1]

    Deferred.new do
      (arr + (+Service.primary.twitter.favorited_by(id: id))).uniq
    end
  end

  # この投稿を「自分」がふぁぼっていれば真
  def favorited_by_me?(me = Service.services)
    case me
    when Diva::Model
      me.class.slug == :twitter && favorited_by.include?(me.user_obj)
    when Enumerable
      not (Set.new(favorited_by.map(&:idname)) & Set.new(me.select{|w|w.class.slug == :twitter}.map(&:idname))).empty?
    else
      raise ArgumentError, "first argument should be `Service' or `Enumerable'. but given `#{me.class}'" end end

  # この投稿をリツイートしたユーザを返す
  # ==== Return
  # Enumerable リツイートしたユーザを、リツイートした順番に返す
  def retweeted_by_d
    has_status_user_ids = Set.new(retweeted_statuses.map(&:user).map(&:id))
    arr = retweeted_sources.lazy.reject{|r|
      r.class.slug == :twitter_user and has_status_user_ids.include?(r.id)
    }.map(&:user)

    Deferred.new do
      (arr.to_a + (+Service.primary.twitter.retweeted_by(id: id))).uniq
    end
  end

  # この投稿に対するリツイートを返す
  def retweeted_statuses
    retweeted_sources.lazy.select{|m| m.is_a?(Plugin::Twitter::Message) }
  end

  # この投稿に対するリツイートまたはユーザを返す
  def retweeted_sources
    @retweets ||= Plugin.filtering(:retweeted_by, self, Set.new())[1].to_a.compact end

  # 選択されているユーザがこのツイートをリツイートしているなら真
  def retweeted?(world=nil)
    unless world
      world, = Plugin.filtering(:world_current, nil)
    end
    retweeted_users.include?(world.user_obj) if world.class.slug == :twitter
  end
  deprecate :retweeted?, "spell (see: https://reference.mikutter.hachune.net/reference/2017/11/28/spell.html#shared-twitter-tweet)", 2018, 11

  # この投稿を「自分」がリツイートしていれば真
  def retweeted_by_me?(world = Enumerator.new{|y| Plugin.filtering(:worlds, y) })
    case world
    when Diva::Model
      retweeted?(world)
    when Enumerable
      our = Set.new(world.select{|w| w.class.slug == :twitter }.map(&:user_obj))
      retweeted_users.any?(&our.method(:include?))
    end
  end
  deprecate :retweeted_by_me?, "spell (see: https://reference.mikutter.hachune.net/reference/2017/11/28/spell.html#shared-twitter-tweet)", 2018, 11

  # この投稿をリツイート等して、 _me_ のタイムラインに出現させたリツイートを返す。
  # 特に誰もリツイートしていない場合は _self_ を返す。
  # リツイート、ふぁぼなどを行う時に使用する。
  # ==== Args
  # [me] Service 対象とするService
  # ==== Return
  # Message
  def introducer(me = Service.primary!)
    Plugin.filtering(:message_introducers, me, self, retweeted_statuses.reject{|m|m.user == me.to_user}).last.to_a.last || self
  end

  # 非公式リツイートやハッシュタグを適切に組み合わせて投稿する
  def body
    self[:message].to_s.freeze
  end

  def description
    self[:message].to_s.gsub(Plugin::Twitter::Message::DESCRIPTION_UNESCAPE_REGEXP, &Plugin::Twitter::Message::DESCRIPTION_UNESCAPE_RULE)
  end

  # Message#body と同じだが、投稿制限文字数を超えていた場合には、収まるように末尾を捨てる。
  def to_s
    body[0,140].freeze end
  memoize :to_s

  def to_i
    self[:id].to_i end

  # :nodoc:
  def message
    self end

  # :nodoc:
  def to_message
    self end

  deprecate :message, :none, 2017, 05
  deprecate :to_message, :none, 2017, 05

  # 本文を人間に読みやすい文字列に変換する
  def to_show
    @to_show ||= body.gsub(DESCRIPTION_UNESCAPE_REGEXP, &DESCRIPTION_UNESCAPE_RULE).freeze end

  # このMessageのパーマリンクを取得する
  # ==== Return
  # 次のいずれか
  # [URI] パーマリンク
  # [nil] パーマリンクが存在しない
  def perma_link
    Diva::URI.new("https://twitter.com/#{user[:idname]}/status/#{self[:id]}") end
  memoize :perma_link
  alias :parma_link :perma_link
  deprecate :parma_link, "perma_link", 2016, 12

  # :nodoc:
  def add_favorited_by(user, time=Time.now)
    type_strict user => Plugin::Twitter::User, time => Time
    return retweet_source.add_favorited_by(user, time) if retweet?
    service = Service.primary
    if service
      set_modified(time) if UserConfig[:favorited_by_anyone_age] and (UserConfig[:favorited_by_myself_age] or service.user_obj != user)
      favorited_by.add(user)
      Plugin.call(:favorite, service, user, self) end end

  # :nodoc:
  def remove_favorited_by(user)
    type_strict user => Plugin::Twitter::User
    return retweet_source.remove_favorited_by(user) if retweet?
    service = Service.primary
    if service
      favorited_by.delete(user)
      Plugin.call(:unfavorite, service, user, self) end end

  # :nodoc:
  def add_child(child)
    type_strict child => Plugin::Twitter::Message
    if child[:retweet]
      add_retweet_in_this_thread(child)
    else
      add_child_in_this_thread(child)
    end
  end

  # :nodoc:
  def add_retweet_user(retweet_user, created_at)
    type_strict retweet_user => Plugin::Twitter::User
    return retweet_source.add_retweet_user(retweet_user, created_at) if retweet?
    add_retweet_in_this_thread(retweet_user, created_at)
  end

  # 最終更新日時を取得する
  def modified
    @value[:modified] ||= [created, *(@retweets || []).map{ |x| x.modified }].compact.max
  end

  def inspect
    "#<#{self.class.name}: #{id} #{user.inspect} #{to_show}>"
  end

  private

  def add_retweet_in_this_thread(child, created_at=child[:created])
    unless retweeted_sources.include? child
      case child.class.slug
      when :twitter_tweet
        retweeted_sources << child
        retweeted_sources.delete(child.user) if retweeted_sources.include?(child.user)
      when :twitter_user
        retweeted_sources << child if retweeted_users.include?(child)
      end
    end
    world, = Plugin.filtering(:world_current, nil)
    set_modified(created_at) if world and world.class.slug == :twitter and UserConfig[:retweeted_by_anyone_age] and ((UserConfig[:retweeted_by_myself_age] or world.user_obj != child.user))
  end

  def add_child_in_this_thread(child)
    children << child
  end

  def set_modified(time)
    if modified < time
      self[:modified] = time
      Plugin::call(:message_modified, self) end
    self end

  class DataSource < Diva::Model::Memory
    def initialize
      super(Plugin::Twitter::Message)
    end

    def findbyid(id, policy)
      if id.is_a? Enumerable
        super.map do |v|
          case v
          when Plugin::Twitter::Message
            v
          else
            findbyid(v)
          end
        end
      else
        result = super
        if result
          result
        elsif policy == Diva::DataSource::USE_ALL
          twitter = Enumerator.new{|y|
            Plugin.filtering(:worlds, y)
          }.find{|world|
            world.class.slug == :twitter
          }
          twitter.status_show(id: id) if twitter
        end
      end
    rescue Exception => err
      error err
      raise err
    end
  end

  #
  # Sub classes
  #

  # 添付画像
  class Image
    attr_accessor :url
    attr_reader :resource

    IS_URL = /\Ahttps?:\/\//

    def initialize(resource)
      if(not resource.is_a?(IO)) and (FileTest.exist?(resource.to_s)) then
        @resource = open(resource)
      else
        @resource = resource
        if((IS_URL === resource) != nil) then
          @url = resource
        end
      end
    end

    def path
      if(@resource.is_a?(File)) then
        return @resource.path
      end
      return @url
    end
  end

  # 例外を引き起こした原因となるMessageをセットにして例外を発生させることができる
  class MessageError < Diva::DivaError
    # messageは、Exceptionクラスと名前が被る
    attr_reader :message

    def initialize(body, message)
      super("#{body} occurred by #{message[:id]}(#{message[:message]})")
      @message = message end

  end

end

class Messages < TypedArray(Plugin::Twitter::Message)
end

Message = Plugin::Twitter::Message
