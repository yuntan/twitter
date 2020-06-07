Plugin.create :twitter do
  Deferred.new do
    # fetch user timeline
    collect(:twitter_worlds).each do |world|
      world.twitter.user_timeline.trap { |err| error err }
    end

    last_fetch = {}

    while true
      collect(:twitter_worlds).each do |world|
        # fetch home timeline periodically
        slug = Stream.friends(world).datasource_slug
        interval = UserConfig[:twitter_retrieve_interval_friends]
        unless last_fetch[slug] && Time.now < last_fetch[slug] + interval
          generate :extract_receive_message, slug do |stream|
            world.twitter.friends_timeline
              .next(&stream.method(:bulk_add))
              .trap { |err| error err }
              .next { last_fetch[slug] = Time.now }
          end
        end

        # fetch replies periodically
        slug = :"#{world.slug}-replies"
        interval = UserConfig[:twitter_retrieve_interval_replies]
        unless last_fetch[slug] && Time.now < last_fetch[slug] + interval
          world.twitter.replies
            .trap { |err| error err }
            .next { last_fetch[slug] = Time.now }
        end

        # fetch lists periodically
        interval = UserConfig[:twitter_retrieve_interval_lists]
        extract_lists.each do |slug, a|
          unless last_fetch[slug] && Time.now < last_fetch[slug] + interval
            generate :extract_receive_message, slug do |stream|
              idname, list_id = a
              idname == world.idname or next
              world.twitter.list_statuses(id: list_id)
                .next(&stream.method(:bulk_add))
                .trap { |err| error err }
                .next { last_fetch[slug] = Time.now }
            end
          end
        end
      end

      +(Deferred.sleep 15)
    end
  end.trap { |err| error err }


  def extract_lists
    Plugin.filtering(:active_datasources, Set.new).last.reduce({}) do |h, slug|
      if slug.to_s =~ /^twitter-([a-zA-Z0-9_]+)-list-(\d+)$/
        h[slug] = [$1, $2.to_i]
      end
      h
    end
  end
end
