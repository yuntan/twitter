# frozen_string_literal: true

UserConfig[:twitter_retrieve_period_friends] ||= 15 # seconds
UserConfig[:twitter_retrieve_period_replies] ||= 30 # seconds
UserConfig[:twitter_retrieve_period_lists] ||= 15 # seconds

Plugin.create :twitter do
  settings _('Twitter') do
    settings _('APIキー') do
      input _('CK'), :twitter_ck
      input _('CS'), :twitter_cs
      boolean _('xAuthを使う'), :use_xauth
    end

    settings _('更新間隔') do
      adjustment _('ホームタイムライン（秒）'),
                 :twitter_retrieve_period_friends,
                 5, 60
      adjustment _('メンション（秒）'),
                 :twitter_retrieve_period_replies,
                 12, 60
      adjustment _('リスト（秒）'),
                 :twitter_retrieve_period_lists,
                 1, 60
    end
  end
end

# Twitter for iOS
UserConfig[:twitter_ck] ||= 'IQKbtAYlXLripLGPWd0HUA'
UserConfig[:twitter_cs] ||= 'GgDYlkSvaPxGxC4X8liwpUoqKwwr3lCADbz8A7ADU'
UserConfig[:twitter_use_xauth].nil? and UserConfig[:twitter_use_xauth] = true
# 君は何も見ていない，いいね？
