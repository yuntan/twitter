Plugin.create :twitter do
  Deferred.new do
    # fetch user timeline
    collect(:twitter_worlds).each do |world|
      world.twitter.user_timeline.trap { |err| error err }
    end

    last_fetch = %i[friends_timeline replies lists]
      .map { |slug| [slug, Time.now] }.to_h

    while true
      collect(:twitter_worlds).each do |world|
        # fetch home timeline periodically
        datasource_slug = Stream.friends(world.idname).datasource_slug
        generate :extract_receive_message, datasource_slug do |stream|
          period = UserConfig[:twitter_retrieve_period_friends]
          next if Time.now < last_fetch[:friends_timeline] + period

          world.twitter.friends_timeline
            .next(&stream.method(:bulk_add))
            .trap { |err| error err }
            .next { last_fetch[:friends_timeline] = Time.now }
        end

        # fetch replies periodically
        period = UserConfig[:twitter_retrieve_period_replies]
        if Time.now > last_fetch[:replies] + period
          world.twitter.replies
            .trap { |err| error err }
            .next { last_fetch[:replies] = Time.now }
        end

        # fetch lists periodically
        world.twitter.lists(user: world.user).next do |lists|
          lists.each do |list|
            datasource_slug = Stream.list(world.idname, list.id).datasource_slug
            generate :extract_receive_message, datasource_slug do |stream|
              period = UserConfig[:twitter_retrieve_period_lists]
              next if Time.now < last_fetch[:lists] + period

              notice "start #{list.id}"
              world.twitter.list_statuses(id: list.id, public: list.public?)
                .next(&stream.method(:bulk_add))
                .trap { |err| error err }
                .next { notice "end #{list.id}" }
                .next { last_fetch[:lists] = Time.now }
            end
          end
        end.trap { |err| error err }
      end

      +(Deferred.sleep 15)
    end
  end
end
