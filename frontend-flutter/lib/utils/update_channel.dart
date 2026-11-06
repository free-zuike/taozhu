import 'package:shared_preferences/shared_preferences.dart';

/// 更新通道：正式版只认 GitHub 最新 Release；预发布版额外接收 prerelease。
///
/// 默认正式版——CI 在 bugfix 独立分支发的预发布版不会推给普通用户，
/// 只有主动打开预发布通道的用户才参与验证（用户定稿：确认没问题后再发正式版）。
enum UpdateChannel { stable, preview }

const _channelKey = 'taozhu.update_channel';

UpdateChannel _current = UpdateChannel.stable;
UpdateChannel get currentUpdateChannel => _current;

Future<UpdateChannel> loadUpdateChannel() async {
  try {
    final p = await SharedPreferences.getInstance();
    _current = p.getString(_channelKey) == 'preview'
        ? UpdateChannel.preview
        : UpdateChannel.stable;
  } catch (_) {}
  return _current;
}

Future<void> saveUpdateChannel(UpdateChannel channel) async {
  _current = channel;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_channelKey, channel == UpdateChannel.preview ? 'preview' : 'stable');
  } catch (_) {}
}

String updateChannelLabel(UpdateChannel channel) =>
    channel == UpdateChannel.preview ? '预发布版（抢先验证）' : '正式版（默认）';
