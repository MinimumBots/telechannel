require 'bundler/setup'
require 'discordrb'
require 'discordrb/webhooks/client'

class Telechannel
  WEBHOOK_NAME_REG = /^Telehook<(\d+)>$/

  def initialize(bot_token)
    @bot = Discordrb::Commands::CommandBot.new(
      token: bot_token,
      prefix: '+',
      help_command: false,
      webhook_commands: false,
      ignore_bots: true
    )

    @link_queues = Hash.new { |hash, key| hash[key] = {} }  # 接続待機
    @link_pairs  = Hash.new { |hash, key| hash[key] = {} }  # 接続済み

    # BOT初期化処理
    @bot.ready do
      @bot.game = "#{@bot.prefix}help"
    end

    # コマンド共通属性
    @command_attrs = {
      permission_message: "⚠ **#{@bot.prefix}%name%** コマンドの実行には **チャンネル管理** 権限が必要です",
      required_permissions: [:manage_channels]
    }

    # コネクション作成
    @bot.command(:link, @command_attrs) do |event, p_channel_id|
      if p_channel_id !~ /^\d+$/
        event.send_message("⚠ チャンネルIDを指定してください")
        next
      end
      add_link(event.channel, p_channel_id.to_i)
      nil
    end

    # コネクション削除
    @bot.command(:unlink, @command_attrs) do |event, p_channel_id|
      if p_channel_id !~ /^\d+$/
        event.send_message("⚠ チャンネルIDを指定してください")
        next
      end
      remove_link(event.channel, p_channel_id.to_i)
      nil
    end

    # 接続中のチャンネルを表示
    @bot.command(:list, @command_attrs) do |event|
      resume_links(event.channel)
      event.send_embed do |embed|
        embed.title = "接続中のチャンネル一覧"
        embed.description = ""
        if get_pair_list(event.channel).each do |item|
          embed.description += "#{item[:server_name]} ##{item[:channel_name]} : **`#{item[:channel_id]}`**\n"
        end.empty?
          embed.description = "(接続中のチャンネルはありません)"
        end
      end
    end

    # 全コネクションを削除
    @bot.command(:clear, @command_attrs) do |event|
      remove_all_links(event.channel)
      nil
    end

    @bot.command(:help, @command_attrs) do |event|
      event.send_embed do |embed|
        embed.title = "コマンド一覧"
        embed.description = <<DESC
**`+link (相手のチャンネルID)`** : 指定されたチャンネルと接続します
**`+unlink (相手のチャンネルID)`** : 指定されたチャンネルを切断します
**`+list`** : このチャンネルに接続されているチャンネルを表示します
**`+clear`** : このチャンネルの接続を全て切断します

このチャンネルのIDは **`#{event.channel.id}`** です
DESC
      end
    end

    @bot.command(:ping) do |event|
      message = event.send_message("計測中...")
      message.edit("応答時間: #{((message.timestamp - event.timestamp) * 1000).round}ms")
    end

    @bot.command(:neko) do |event|
      path = File.expand_path('../neko.png', __FILE__)
      event.channel.send_file(File.open(path, 'r'), caption: "ねこです。よろしくおねがいします。")
    end

    # Webhook更新イベント
    @bot.webhook_update do |event|
      check_links(event.channel)
      nil
    end

    # メッセージイベント
    @bot.message do |event|
      next unless event.channel.text?
      send_content(event)
      nil
    end
  end

  # BOT起動
  def run(async = false)
    @bot.run(async)
  end

  private

  # ペアまたはキューに登録
  def add_link(channel, p_channel_id, no_msg = false)
    # チャンネル取得
    p_channel = get_p_channel(p_channel_id, channel && !no_msg)
    return unless p_channel
    if p_channel.id == channel.id
      channel.send_message("⚠ **指定されたチャンネルはこのチャンネルです**") unless no_msg
      return
    end

    # 登録済み確認
    if @link_queues[channel.id][p_channel.id]
      channel.send_message(
        "ℹ **指定されたチャンネルは接続を待っています**\n" + 
        "相手チャンネルで次のコマンドを実行してください **`#{@bot.prefix}link #{channel.id}`**"
      ) unless no_msg
      return
    end
    if @link_pairs[channel.id][p_channel.id]
      channel.send_message("ℹ **指定されたチャンネルは接続済みです**") unless no_msg
      return
    end

    # ウェブフックを作成
    webhook = get_webhook(channel, p_channel)
    return unless webhook

    # キューを取り出す
    p_webhook = @link_queues[p_channel.id].delete(channel.id)

    if p_webhook.nil?
      # キューに登録
      @link_queues[channel.id][p_channel.id] = webhook
      channel.send_message(
        "ℹ **#{p_channel.server.name} ##{p_channel.name}** との接続を待っています\n" +
        "相手チャンネルで次のコマンドを実行してください **`#{@bot.prefix}link #{channel.id}`**"
      ) unless no_msg
    else
      # ペアに登録
      @link_pairs[channel.id][p_channel.id] = p_webhook
      @link_pairs[p_channel.id][channel.id] = webhook
      channel.send_message("✅ **#{p_channel.server.name} ##{p_channel.name}** と接続されました") unless no_msg
      p_channel.send_message("✅ **#{channel.server.name} ##{channel.name}** と接続されました") unless no_msg
    end

    p_channel
  end

  # ペアまたはキューの削除
  def remove_link(channel, p_channel_id, no_msg = false)
    # チャンネル取得
    p_channel = get_p_channel(p_channel_id)
    if p_channel && p_channel.id == channel.id
      channel.send_message("⚠ **指定されたチャンネルはこのチャンネルです**") unless no_msg
      return
    end

    p_webhook = @link_pairs[channel.id].delete(p_channel_id)

    # キューの削除
    if p_webhook.nil?
      webhook = @link_queues[channel.id].delete(p_channel_id)
      if webhook
        begin; webhook.delete
        rescue; nil; end
        if p_channel
          channel.send_message("ℹ **#{p_channel.server.name} ##{p_channel.name}** の接続待ちがキャンセルされました") unless no_msg
        else
          channel.send_message("ℹ 接続待ちがキャンセルされました") unless no_msg
        end
      else
        channel.send_message("⚠ **指定されたチャンネルは接続されていません**") unless no_msg

        # 未登録のWebhookを削除
        channel.webhooks.each do |webhook|
          next if webhook.owner.id != @bot.profile.id
          next if webhook.name !~ WEBHOOK_NAME_REG || $1.to_i != p_channel_id
          webhook.delete
        end
      end
      return p_channel
    end

    # ペアの削除
    webhook = @link_pairs[p_channel_id].delete(channel.id)
    if webhook
      begin; webhook.delete
      rescue; nil; end
      if p_channel
        channel.send_message("⛔ **#{p_channel.server.name} ##{p_channel.name}** と切断されました") unless no_msg
      else
        channel.send_message("⛔ 接続相手と切断されました") unless no_msg
      end
    end
    
    begin; p_webhook.delete
    rescue; nil; end
    if p_channel
      p_channel.send_message("⛔ **#{channel.server.name} ##{channel.name}** と切断されました") unless no_msg
    end

    p_channel
  end

  # すべての接続を切断
  def remove_all_links(channel)
    # ペア情報を元にWebhookを削除
    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      remove_link(channel, p_channel_id)
    end

    # チャンネルのWebhookを削除
    channel.webhooks.each do |webhook|
      webhook.delete if webhook.owner.id == @bot.profile.id
    end
  end

  # 接続確認
  def check_links(channel)
    webhook_ids = channel.webhooks.map do |webhook|
      webhook.name =~ WEBHOOK_NAME_REG
      [webhook.id, $1.to_i]
    end.to_h

    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      webhook = @link_pairs[p_channel_id][channel.id]
      unless webhook_ids.has_key?(webhook.id) && webhook_ids[webhook.id] == p_channel_id
        remove_link(channel, p_channel_id)
      end
    end
  end

  # メッセージ送信
  def send_content(event)
    channel = event.channel
    message = event.message

    resume_links(channel)

    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      client = Discordrb::Webhooks::Client.new(id: p_webhook.id, token: p_webhook.token)

      if message.author.respond_to?(:display_name)
        display_name = message.author.display_name
      else
        display_name = message.author.username
      end

      begin
        client.execute do |builder|
          builder.avatar_url = message.author.avatar_url
          builder.username   = "#{display_name} (@#{channel.server.name} ##{channel.name})"
          
          message.attachments.each do |attachment|
            builder.content += "📎 #{attachment.url}\n"
          end
          builder.content += message.content
        end
      rescue RestClient::NotFound
        remove_link(channel, p_channel_id)
      end
    end
  end

  # 接続再構築
  def resume_links(channel)
    return if @link_pairs.has_key?(channel.id) || @link_queues.has_key?(channel.id)

    channel.webhooks.each do |webhook|
      next if webhook.owner.id != @bot.profile.id
      next if webhook.name !~ WEBHOOK_NAME_REG
      p_channel_id = $1.to_i

      # キュー登録
      p_channel = add_link(channel, p_channel_id, true)
      unless p_channel
        remove_link(channel, p_channel_id)
        next
      end

      # ペア登録
      p_channel.webhooks.each do |webhook|
        next if webhook.owner.id != @bot.profile.id
        next if webhook.name !~ WEBHOOK_NAME_REG || $1.to_i != channel.id
        add_link(p_channel, channel.id, true)
      end
    end
  end

  # 相手チャンネルを取得
  def get_p_channel(p_channel_id, channel = nil)
    begin
      p_channel = @bot.channel(p_channel_id)
    rescue Discordrb::Errors::NoPermission
      channel.send_message("⚠ **指定されたチャンネルにBOTが導入されていません**") if channel
      return nil
    end

    if p_channel.nil?
      channel.send_message("⚠ **指定されたチャンネルは存在しません**") if channel
      return nil
    end

    p_channel
  end

  # Webhookの取得または作成
  def get_webhook(channel, p_channel)
    # 既存のWebhookを取得
    begin
      webhooks = channel.webhooks.select do |webhook|
        webhook.name =~ WEBHOOK_NAME_REG
        $1.to_i == p_channel.id && webhook.owner.id == @bot.profile.id
      end
    rescue Discordrb::Errors::NoPermission
      channel.send_message("⚠ BOTに **ウェブフックの管理** 権限が必要です")
      return nil
    end

    # Webhookを作成
    if webhooks.empty?
      begin
        webhook = channel.create_webhook("Telehook<#{p_channel.id}>")
      rescue Discordrb::Errors::NoPermission
        channel.send_message("⚠ BOTに **ウェブフックの管理** 権限が必要です")
        return nil
      end
      return webhook
    end

    webhooks.first
  end

  # 接続済みリスト取得
  def get_pair_list(channel)
    @link_pairs[channel.id].map do |p_channel_id, p_webhook|
      p_channel = get_p_channel(p_channel_id)
      next unless p_channel
      { server_name: p_channel.server.name, channel_name: p_channel.name, channel_id: p_channel.id }
    end
  end
end
