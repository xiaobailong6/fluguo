import 'package:duanju_app/download_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Map<String, dynamic> row(String id, {int created = 1, double progress = 0}) => {
  'id': id,
  'drama': drama(id).toJson(),
  'chapter': <String, dynamic>{},
  'index': 1,
  'created': created,
  'state': 'downloading',
  'progress': progress,
};

void main() {
  test('千条历史中只替换变更模型，同游标复用列表', () {
    final cache = DownloadSnapshot();
    cache.apply({
      'fingerprint': 'a',
      'jobs': [for (var i = 0; i < 1000; i++) row('$i', created: i)],
    });
    final old = cache.jobs;
    expect(
      cache.apply({
        'fingerprint': 'b',
        'base': 'a',
        'changed': [row('0', created: 0, progress: .5)],
        'removed': [],
      }),
      isTrue,
    );
    expect(cache.jobs.last.progress, .5);
    expect(cache.jobs.first, same(old.first));
    expect(cache.jobs[998], same(old[998]));
    final next = cache.jobs;
    cache.apply({'fingerprint': 'b'});
    expect(cache.jobs, same(next));
  });

  test('删除新增和同ID重建保持时间及集序排列', () {
    final cache = DownloadSnapshot()
      ..apply({
        'fingerprint': 'a',
        'jobs': [row('a'), row('b', created: 2)],
      });
    final b = cache.jobs.first;
    cache.apply({
      'fingerprint': 'b',
      'base': 'a',
      'changed': [row('a', created: 3)],
      'removed': [],
    });
    expect(cache.jobs.map((job) => job.id), ['a', 'b']);
    expect(cache.jobs.last, same(b));
    cache.apply({
      'fingerprint': 'c',
      'base': 'b',
      'changed': [row('c', created: 4)],
      'removed': ['a'],
    });
    expect(cache.jobs.map((job) => job.id), ['c', 'b']);
    cache.apply({'fingerprint': 'd', 'jobs': []});
    expect(cache.jobs, isEmpty);
  });

  test('基线不匹配或格式错误不破坏已发布快照', () {
    final cache = DownloadSnapshot()
      ..apply({
        'fingerprint': 'a',
        'jobs': [row('a')],
      });
    final old = cache.jobs;
    expect(
      cache.apply({
        'fingerprint': 'c',
        'base': 'b',
        'changed': [],
        'removed': ['a'],
      }),
      isFalse,
    );
    expect(cache.jobs, same(old));
    expect(cache.fingerprint, 'a');
    expect(
      () => cache.apply({
        'fingerprint': 'b',
        'base': 'a',
        'changed': [
          row('b'),
          {'id': 'bad'},
        ],
        'removed': ['a'],
      }),
      throwsA(isA<TypeError>()),
    );
    expect(cache.jobs, same(old));
    expect(cache.fingerprint, 'a');
  });
}
