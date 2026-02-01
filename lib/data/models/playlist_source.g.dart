// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playlist_source.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PlaylistSourceAdapter extends TypeAdapter<PlaylistSource> {
  @override
  final int typeId = 3;

  @override
  PlaylistSource read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlaylistSource(
      id: fields[0] as String,
      name: fields[1] as String,
      type: fields[2] as PlaylistType,
      url: fields[3] as String,
      username: fields[4] as String?,
      password: fields[5] as String?,
      epgUrl: fields[6] as String?,
      createdAt: fields[7] as DateTime,
      lastUpdated: fields[8] as DateTime?,
      isActive: fields[9] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, PlaylistSource obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.type)
      ..writeByte(3)
      ..write(obj.url)
      ..writeByte(4)
      ..write(obj.username)
      ..writeByte(5)
      ..write(obj.password)
      ..writeByte(6)
      ..write(obj.epgUrl)
      ..writeByte(7)
      ..write(obj.createdAt)
      ..writeByte(8)
      ..write(obj.lastUpdated)
      ..writeByte(9)
      ..write(obj.isActive);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistSourceAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PlaylistTypeAdapter extends TypeAdapter<PlaylistType> {
  @override
  final int typeId = 2;

  @override
  PlaylistType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return PlaylistType.m3u;
      case 1:
        return PlaylistType.xtream;
      default:
        return PlaylistType.m3u;
    }
  }

  @override
  void write(BinaryWriter writer, PlaylistType obj) {
    switch (obj) {
      case PlaylistType.m3u:
        writer.writeByte(0);
        break;
      case PlaylistType.xtream:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
