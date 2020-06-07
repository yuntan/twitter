# frozen_string_literal: true

module Plugin::Twitter; end

require_relative 'model/model'
require_relative 'mikutwitter/mikutwitter'
require_relative 'oauth/oauth'
require_relative 'service'
require_relative 'settings'
require_relative 'retriever'

Plugin.create(:twitter) do
  pt = Plugin::Twitter

  defevent :twitter_worlds, prototype: [Pluggaloid::COLLECT]

  defevent :twitter_appear_tweets, prototype: [Pluggaloid::STREAM]

  defevent :favorite,
           priority: :ui_favorited,
           prototype: [Diva::Model, Plugin::Twitter::User, Plugin::Twitter::Message]

  defevent :unfavorite,
           priority: :ui_favorited,
           prototype: [Diva::Model, Plugin::Twitter::User, Plugin::Twitter::Message]

  defactivity :twitter, _('Twitter')

  favorites = Hash.new{ |h, k| h[k] = Set.new } # {user_id: set(message_id)}
  unfavorites = Hash.new{ |h, k| h[k] = Set.new } # {user_id: set(message_id)}

  generate :extract_receive_message, :twitter_appear_tweets do |stream|
    subscribe(:twitter_appear_tweets, &stream.method(:bulk_add))
  end

  subscribe(:twitter_appear_tweets).each do |tweet|
    tweet.retweet? and Plugin.call(:share, tweet.user, tweet.retweet_ancestor)
    # tweet.to_me? and Plugin.call(:mention, world, [tweet])
  end

  collection :message_stream do |collector|
    collector << Stream.all

    subscribe :twitter_worlds__add do |worlds|
      collector.rewind do |a|
        a | worlds.map(&Stream.method(:friends))
      end
      worlds.each do |world|
        world.twitter.lists.next do |lists|
          collector.rewind do |a|
            a | lists.map { |list| Stream.list world, list }
          end
        end.trap { error err }
      end
    end
  end

  collection :twitter_worlds do |collector|
    subscribe(:worlds__add)
      .select { |world| world.class.slug == :twitter }
      .each(&collector.method(:add))

    subscribe(:worlds__delete).each(&collector.method(:delete))
  end

  # Serviceと、Messageの配列を受け取り、一度以上受け取ったことのあるものを除外して返すフィルタを作成して返す。
  # ただし、除外したかどうかはService毎に記録する。
  # また、アカウント登録前等、serviceがnilの時はシステムメッセージ以外を全て削除し、記録しない。
  # ==== Return
  # フィルタのプロシージャ(Proc)
  def gen_message_filter_with_service
    service_filters = Hash.new{|h,k|h[k] = gen_message_filter}
    ->(service, messages, &cancel) do
      if service
        [service] + service_filters[service.user_obj.id].(messages)
      else
        system = messages.select(&:system?)
        if system.empty?
          cancel.call
        else
          [nil, system]
        end
      end
    end
  end

  # Messageの配列を受け取り、一度以上受け取ったことのあるものを除外して返すフィルタを作成して返す
  # ==== Return
  # フィルタのプロシージャ(Proc)
  def gen_message_filter
    appeared = Set.new
    ->(messages) do
      [messages.select{ |message| appeared.add(message.id) unless appeared.include?(message.id) }]
    end
  end

  filter_update(&gen_message_filter_with_service)

  filter_mention(&gen_message_filter_with_service)

  filter_direct_messages(&gen_message_filter_with_service)

  filter_appear(&gen_message_filter)

  defspell(:destroy, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet){ tweet.from_me?(twitter) }
          ) do |twitter, tweet|
    (twitter/"statuses/destroy".freeze/tweet.id).message.next{ |destroyed_tweet|
      destroyed_tweet[:rule] = :destroy
      Plugin.call(:destroyed, [destroyed_tweet])
      destroyed_tweet
    }
  end

  defspell(:destroy_share, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet){ shared?(twitter, tweet) }
          ) do |twitter, tweet|
    shared(twitter, tweet).next{ |retweet|
      destroy(twitter, retweet)
    }
  end

  defspell(:favorite, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet){
             !favorited?(twitter, tweet)
           }) do |twitter, tweet|
    Plugin.call(:before_favorite, twitter, twitter.user_obj, tweet)
    (twitter/'favorites/create'.freeze).message(id: tweet.id).next{ |favorited_tweet|
      Plugin.call(:favorite, twitter, twitter.user_obj, favorited_tweet)
      favorited_tweet
    }.trap{ |e|
      Plugin.call(:fail_favorite, twitter, twitter.user_obj, tweet)
      Deferred.fail(e)
    }
  end

  defspell(:favorited, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet){ favorited?(twitter.user_obj, tweet) }
          ) do |twitter, tweet|
    Delayer::Deferred.new.next{
      favorited?(twitter.user, tweet)
    }
  end

  defspell(:favorited, :twitter_user, :twitter_tweet,
           condition: ->(user, tweet){ tweet.favorited_by.include?(user) }
          ) do |user, tweet|
    Delayer::Deferred.new.next{
      favorited?(user, tweet)
    }
  end

  defspell(:compose, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet, visibility: nil){
             !(visibility && visibility != :public)
           }) do |twitter, tweet, body:, **options|
    twitter.post_tweet(message: body, replyto: tweet, **options)
  end

  defspell(:compose, :twitter, :twitter_direct_message,
           condition: ->(twitter, direct_message, visibility: nil){
             !(visibility && visibility != :direct)
           }) do |twitter, direct_message, body:, **options|
    twitter.post_dm(user: direct_message.user, text: body, **options)
  end

  defspell(:compose, :twitter, :twitter_user,
           condition: ->(twitter, user, visibility: nil){
             !(visibility && ![:public, :direct].include?(visibility))
           }) do |twitter, user, visibility: nil, body:, **options|
    case visibility
    when :public, nil
      twitter.post_tweet(message: body, receiver: user, **options)
    when :direct
      twitter.post_dm(user: user, text: body, **options)
    else
      raise "invalid visibility `#{visibility.inspect}'."
    end
  end

  # 宛先なしのタイムラインへのツイートか、 _to_ オプション引数で複数宛てにする場合。
  # Twitterでは複数宛先は対応していないため、 _to_ オプションの1つめの値に対する投稿とする
  defspell(:compose, :twitter,
           condition: ->(twitter, to: nil){
             first = Array(to).compact.first
             !(first && !compose?(twitter, first))
           }) do |twitter, body:, to: nil, **options|
    first = Array(to).compact.first
    if first
      compose(twitter, first, body: body, **options)
    else
      twitter.post_tweet(to: to, message: body, **options)
    end
  end

  defspell(:share, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet){ !tweet.protected? }
          ) do |twitter, tweet|
    twitter.retweet(id: tweet.id).next{|retweeted|
      Plugin.call(:posted, twitter, [retweeted])
      Plugin.call(:update, twitter, [retweeted])
      retweeted
    }
  end

  defspell(:shared, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet){ tweet.retweeted_users.include?(twitter.user_obj) }
          ) do |twitter, tweet|
    Delayer::Deferred.new.next{
      retweet = tweet.retweeted_statuses.find{|rt| rt.user == twitter.user_obj }
      if retweet
        retweet
      else
        raise "ReTweet not found."
      end
    }
  end

  defspell(:unfavorite, :twitter, :twitter_tweet,
           condition: ->(twitter, tweet){
             favorited?(twitter, tweet)
           }) do |twitter, tweet|
    (twitter/'favorites/destroy'.freeze).message(id: tweet.id).next{ |unfavorited_tweet|
      Plugin.call(:unfavorite, twitter, twitter.user_obj, unfavorited_tweet)
      unfavorited_tweet
    }
  end

  defspell(:search, :twitter) do |twitter, **options|
    twitter.search(**options)
  end

  defspell(:update_profile_name, :twitter) do |twitter, name:|
    (twitter/'account/update_profile').user(name: name)
  end

  defspell(:update_profile_location, :twitter) do |twitter, location:|
    (twitter/'account/update_profile').user(location: location)
  end

  defspell(:update_profile_url, :twitter) do |twitter, url:|
    (twitter/'account/update_profile').user(url: url)
  end

  defspell(:update_profile_biography, :twitter) do |twitter, biography:|
    (twitter/'account/update_profile').user(description: biography)
  end

  defspell(:update_profile_icon, :twitter, :photo) do |twitter, photo|
    photo.download.next{ |downloaded|
      (twitter/'account/update_profile_image').user(image: Base64.encode64(downloaded.blob))
    }
  end

  defspell(:remain_charcount, :twitter) do |_twitter, body:|
    tweet = Twitter::TwitterText::Validation.parse_tweet(trim_hidden_regions(body))
    280 - tweet[:weighted_length]
  end

  defspell(:around_message, :twitter_tweet) do |message|
    Thread.new do
      message.around(true)
    end
  end

  def trim_hidden_regions(text)
    trim_hidden_header(trim_hidden_footer(text))
  end

  # 文字列からhidden headerを除いた文字列を返す。
  # hidden headerが含まれていない場合は、 _text_ を返す。
  def trim_hidden_header(text)
    return text unless UserConfig[:auto_populate_reply_metadata]
    mentions = text.match(%r[\A((?:@[a-zA-Z0-9_]+\s+)+)])
    forecast_receivers_sn = Set.new
    if reply?
      @to.first.each_ancestor.each do |m|
        forecast_receivers_sn << m.user.idname
        forecast_receivers_sn.merge(m.receive_user_idnames)
      end
    end
    if mentions
      specific_screen_names = Set.new(mentions[1].split(/\s+/).map{|s|s[1, s.size]})
      [*(specific_screen_names - forecast_receivers_sn).map{|s|"@#{s}"}, text[mentions.end(0),text.size]].join(' '.freeze)
    else
      text
    end
  end

  # 文字列からhidden footerを除いた文字列を返す。
  # hidden footerが含まれていない場合は、 _text_ を返す。
  def trim_hidden_footer(text)
    attachment_url = text.match(%r[\A(.*?)\s+(https?://twitter.com/(?:#!/)?(?:[a-zA-Z0-9_]+)/status(?:es)?/(?:\d+)(?:\?.*)?)\Z]m)
    if attachment_url
      attachment_url[1]
    else
      text
    end
  end

  # リツイートを削除した時、ちゃんとリツイートリストからそれを削除する
  on_destroyed do |messages|
    messages.each{ |message|
      if message.retweet?
        source = message.retweet_source(false)
        if source
          Plugin.call(:retweet_destroyed, source, message.user, message[:id])
          source.retweeted_sources.delete(message) end end } end

  # 同じツイートに対するfavoriteイベントは一度しか発生させない
  filter_favorite do |service, user, message|
    Plugin.filter_cancel! if favorites[user[:id]].include? message[:id]
    favorites[user[:id]] << message[:id]
    [service, user, message]
  end

  # 同じツイートに対するunfavoriteイベントは一度しか発生させない
  filter_unfavorite do |service, user, message|
    Plugin.filter_cancel! if unfavorites[user[:id]].include? message[:id]
    unfavorites[user[:id]] << message[:id]
    [service, user, message]
  end

  # followers_createdイベントが発生したら、followイベントも発生させる
  on_followers_created do |service, users|
    users.each do |user|
      Plugin.call(:follow, user, service.user_obj)
    end
  end

  # followings_createdイベントが発生したら、followイベントも発生させる
  on_followings_created do |service, users|
    users.each do |user|
      Plugin.call(:follow, service.user_obj, user)
    end
  end

  # Twitter Entity情報を元にScoreをあれする
  filter_score_filter do |message, note, yielder|
    if message == note && %i<twitter_tweet twitter_direct_message>.include?(message.class.slug)
      score = score_by_entity(message) + quoted_status_permalink(message) + extended_entity_media(message)
      if !score.all?{|n| n.class.slug == :score_text }
        yielder << score
      end
    end
    [message, note, yielder]
  end

  # 正規表現マッチで、ユーザのSNっぽいやつをユーザページにリンクする
  filter_score_filter do |message, note, yielder|
    if message != note && %i<twitter_tweet twitter_direct_message>.include?(message.class.slug)
      score = score_by_screen_name_regexp(note.description)
      yielder << score if score.size >= 2
    end
    [message, note, yielder]
  end

  # 正規表現マッチで、ハッシュタグっぽいやつをHashTag Modelにリンクする
  filter_score_filter do |message, note, yielder|
    if message != note && %i<twitter_tweet twitter_direct_message>.include?(message.class.slug)
      score = score_by_hashtag_regexp(note.description)
      yielder << score if score.size >= 2
    end
    [message, note, yielder]
  end

  def score_by_entity(tweet)
    score = Array.new
    cur = 0
    text = tweet.body
    tweet[:entities].flat_map{|kind, entities|
      case kind
      when :hashtags
        entity_hashtag(tweet, entities)
      when :urls
        entity_urls(tweet, entities)
      when :user_mentions
        entitiy_users(tweet, entities)
      when :symbols
      # 誰得
      when :media
        entity_media(tweet, entities)
      end
    }.compact.sort_by{|range, _|
      range.first
    }.each do |range, note|
      if range.first != cur
        score << text_note(
          description: text[cur...range.first])
      end
      score << note
      cur = range.last
    end
    if cur == 0
      return [text_note(description: text)]
    end
    if cur != text.size
      score << text_note(
        description: text[cur...text.size])
    end
    score
  end

  # filterstream では引用RTの URLが本文に付与されないので quoted_status_permalink から取り出す
  def quoted_status_permalink(tweet)
    score = Array.new
    permalink = (tweet[:quoted_status_permalink] rescue nil)
    if permalink
      uri = Diva::URI.new(permalink[:expanded] || permalink[:url])
      uri.freeze
      result = Diva::Model(:score_hyperlink).new(
          description: permalink[:display] || permalink[:expanded] || permalink[:url],
          uri: uri)
      # filterstream で流れてくる tweet は以下のようになっているっぽい refs #1285
      # 1. ツイート本文が US-ASCII かつ 140文字以下で filterstream 受信した場合
      #  * text あり full_text なし text は引用RTのURLを 含まない
      #  * entities の urls に引用RTのURLを 含まない (urls は空)
      # 2. ツイート本文が UTF-8 もしくは 140文字超で filterstream 受信した場合
      #  * text なし full_text あり full_text は引用RTのURLを 含まない
      #  * entities の urls に引用RTのURLを 含まない (urls は空)
      #  ……と思っていたら次のような例外が発覚したので個別に対処
      # 3. ツイート本文が UTF-8 かつ 140文字以下で filterstream 受信した場合で
      #    投稿クライアントが Janetter Pro for Android の場合
      #  * text あり full_text なし text は引用RTのURLを 含む
      #  * entities の urls に引用RTのURLを 含む
      text = (tweet[:text] rescue nil)
      text_url = text && text.include?(permalink[:url])
      full_text = (tweet[:full_text] rescue nil)
      full_text_url = full_text && full_text.include?(permalink[:url])
      if !text_url && !full_text_url
        score << text_note(description: ' ')
        score << result
      end
    end
    score
  end

  def extended_entity_media(tweet)
    extended_entities = (tweet[:extended_entities][:media] rescue nil)
    if extended_entities
      newline = text_note(description: "\n")
      result = extended_entities.map{ |media|
        case media[:type]
        when 'photo'
          photo = Diva::Model(:photo)&.generate(photo_variant_seeds(media), perma_link: media[:media_url_https])
          photo ||= Enumerator.new{|y| Plugin.filtering(:photo_filter, media[:media_url_https], y) }.first
          if photo
            Diva::Model(:score_hyperlink).new(
              description: photo.uri,
              uri: photo.uri,
              reference: photo)
          else
            Diva::Model(:score_hyperlink).new(
              description: media[:media_url_https],
              uri: media[:media_url_https])
          end
        when 'video'
          variant = Array(media[:video_info][:variants])
                      .select{|v|v[:content_type] == "video/mp4"}
                      .sort_by{|v|v[:bitrate]}
                      .last
          Diva::Model(:score_hyperlink).new(
            description: "#{media[:display_url]} (%.1fs)" % (media.dig(:video_info, :duration_millis)/1000.0),
            uri: variant[:url])
        when 'animated_gif'
          variant = Array(media[:video_info][:variants])
                      .select{|v|v[:content_type] == "video/mp4"}
                      .sort_by{|v|v[:bitrate]}
                      .last
          Diva::Model(:score_hyperlink).new(
            description: "#{media[:display_url]} (GIF)",
            uri: variant[:url])
        end
      }.flat_map{|media| [newline, media] }
      result
    else
      []
    end
  end

  def photo_variant_seeds(media)
    Enumerator.new do |yielder|
      yielder << { policy: :original,
                   photo: "#{media[:media_url_https]}:orig" }
      media[:sizes].select{ |size_name, size|
        size.has_key?(:w) && size.has_key?(:h) && size.has_key?(:resize)
      }.each do |size_name, size|
        yielder << { name: size_name.to_sym,
                     width: size[:w],
                     height: size[:h],
                     policy: size[:resize].to_sym,
                     photo: "#{media[:media_url_https]}:#{size_name}" }
      end
    end
  end

  def entity_media(tweet, media_list)
    entities_to_notes(media_list) do |media_entity|
      text_note(description: '')
    end
  end

  def entitiy_users(tweet, user_entities)
    entities_to_notes(user_entities) do |user_entity|
      user = Plugin::Twitter::User.findbyid(user_entity[:id], Diva::DataSource::USE_LOCAL_ONLY)
      if user
        Diva::Model(:score_hyperlink).new(
          description: "@#{user.idname}",
          uri: user.uri,
          reference: user)
      else
        screen_name = user_entity[:screen_name] || tweet.body[Range.new(*user_entity[:indices])]
        Diva::Model(:score_hyperlink).new(
          description: "@#{screen_name}",
          uri: "https://twitter.com/#{screen_name}")
      end
    end
  end

  def entity_urls(tweet, urls)
    entities_to_notes(urls) do |url_entity|
      begin
        uri = Diva::URI.new(url_entity[:expanded_url] || url_entity[:url])
        uri.freeze
        Diva::Model(:score_hyperlink).new(
          description: url_entity[:display_url] || url_entity[:expanded_url] || url_entity[:url],
          uri: uri)
      rescue Addressable::URI::InvalidURIError => e
        text_note(description: url_entity[:display_url] || url_entity[:expanded_url] || url_entity[:url])
      end
    end
  end

  def entity_hashtag(tweet, hashtag_entities)
    entities_to_notes(hashtag_entities) do |hashtag|
      Plugin::Twitter::HashTag.new(name: hashtag[:text])
    end
  end

  def entities_to_notes(entities)
    entities.map do |media|
      [ Range.new(*media[:indices], false),
        yield(media) ]
    end
  end

  def score_by_screen_name_regexp(text)
    score_by_regexp(text,
                    pattern: Plugin::Twitter::Message::MentionMatcher,
                    reference_generator: ->(name){ Plugin::Twitter::User.findbyidname(name, Diva::DataSource::USE_LOCAL_ONLY) },
                    uri_generator: ->(name){ "https://twitter.com/#{CGI.escape(name)}" })
  end

  def score_by_hashtag_regexp(text)
    score_by_regexp(text,
                    pattern: /(?:#|＃)[a-zA-Z0-9_]+/,
                    reference_generator: ->(name){ Plugin::Twitter::HashTag.new(name: name) },
                    uri_generator: ->(name){ "https://twitter.com/hashtag/#{CGI.escape(name)}" })
  end

  def score_by_regexp(text, score=Array.new, pattern:, reference_generator:, uri_generator:)
    lead, target, trail = text.partition(pattern)
    score << text_note(description: lead)
    if !(target.empty? || trail.empty?)
      trim = target[1, target.size]
      score << Diva::Model(:score_hyperlink).new(
        description: target,
        uri: uri_generator.(trim),
        reference: reference_generator.(trim))
      score_by_regexp(trail, score,
                      pattern: pattern,
                      reference_generator: reference_generator,
                      uri_generator: uri_generator)
    else
      score
    end
  end

  # TextNoteを作成する。
  # _description:_ から実体参照をアンエスケープした文字列を使ってText Noteを作る。
  # Plugin::Twitter::Message#descriptionの結果が実体参照をエスケープすると
  # Entityのインデックスがずれるので、このメソッドで行う。
  def text_note(description:)
    Diva::Model(:score_text).new(description: description.gsub(Plugin::Twitter::Message::DESCRIPTION_UNESCAPE_REGEXP, &Plugin::Twitter::Message::DESCRIPTION_UNESCAPE_RULE))
  end

  # トークン切れの警告
  MikuTwitter::AuthenticationFailedAction.register do |service, method = nil, url = nil, options = nil, res = nil|
    activity(:system, _("アカウントエラー (@{user})", user: service.user),
             description: _("ユーザ @{user} のOAuth 認証が失敗しました (@{response})\n設定から、認証をやり直してください。",
                            user: service.user, response: res))
    nil
  end

  world_setting :twitter, _('Twitter') do
    ck, cs = UserConfig[:twitter_ck], UserConfig[:twitter_cs]
    token, secret = nil, nil

    while true
      if UserConfig[:twitter_use_xauth]
        xauth = pt::XAuth.new ck, cs

        input _('ユーザー名'), :username
        inputpass _('パスワード'), :password
        result = await_input

        token, secret = await(xauth.authorize(result[:username],
                                  result[:password]).trap do |err|
          error err
          label _("認証に失敗しました。")
          label err.to_s
          [nil, nil]
        end)
        token and break
      else
        oauth = pt::OAuth.new ck, cs
        # HTML escape
        url = oauth.authorize_url.gsub '&', '&amp;'
        text = _('認証ページにアクセスして、表示されたPINを貼り付け、「進む」ボタンを押してください。')
              .sub s, "<a href=\"#{url}\">#{s}</a>"

        markup text
        input _('PIN'), :pin
        result = await_input

        token, secret = await(oauth.authorize(result[:pin]).trap do |err|
          error err
          label _("認証に失敗しました。")
          label err.to_s
          [nil, nil]
        end)
        token and break
      end
    end

    user = +(twitter/:account/:verify_credentials).user
    world = pt::World.new ck: ck, cs: cs, token: token, secret: secret, user: user

    label _("このアカウントでログインしますか？")
    link world.user_obj

    world
  end
end
