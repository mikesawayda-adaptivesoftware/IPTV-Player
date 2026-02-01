// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vod_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class VODItemAdapter extends TypeAdapter<VODItem> {
  @override
  final int typeId = 1;

  @override
  VODItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return VODItem(
      id: fields[0] as String,
      name: fields[1] as String,
      streamUrl: fields[2] as String,
      posterUrl: fields[3] as String?,
      plot: fields[4] as String?,
      year: fields[5] as String?,
      categoryId: fields[6] as String?,
      categoryName: fields[7] as String?,
      rating: fields[8] as double?,
      duration: fields[9] as String?,
      genre: fields[10] as String?,
      director: fields[11] as String?,
      cast: fields[12] as String?,
      isFavorite: fields[13] as bool,
      lastWatched: fields[14] as DateTime?,
      watchProgress: fields[15] as Duration?,
      isSeries: fields[16] as bool,
      seriesId: fields[17] as int?,
      seasonNumber: fields[18] as int?,
      episodeNumber: fields[19] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, VODItem obj) {
    writer
      ..writeByte(20)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.streamUrl)
      ..writeByte(3)
      ..write(obj.posterUrl)
      ..writeByte(4)
      ..write(obj.plot)
      ..writeByte(5)
      ..write(obj.year)
      ..writeByte(6)
      ..write(obj.categoryId)
      ..writeByte(7)
      ..write(obj.categoryName)
      ..writeByte(8)
      ..write(obj.rating)
      ..writeByte(9)
      ..write(obj.duration)
      ..writeByte(10)
      ..write(obj.genre)
      ..writeByte(11)
      ..write(obj.director)
      ..writeByte(12)
      ..write(obj.cast)
      ..writeByte(13)
      ..write(obj.isFavorite)
      ..writeByte(14)
      ..write(obj.lastWatched)
      ..writeByte(15)
      ..write(obj.watchProgress)
      ..writeByte(16)
      ..write(obj.isSeries)
      ..writeByte(17)
      ..write(obj.seriesId)
      ..writeByte(18)
      ..write(obj.seasonNumber)
      ..writeByte(19)
      ..write(obj.episodeNumber);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VODItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
