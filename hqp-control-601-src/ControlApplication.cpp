// $Id: ControlApplication.cpp 13554 2026-03-02 20:33:29Z jussi $

/*

  HQPlayer control application.
  Copyright (C) 2015-2026 Jussi Laako.

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.

*/


#include <QCoreApplication>
#include <QTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QCryptographicHash>

#include "ControlApplication.hpp"


clControlApplication::clControlApplication (QObject *parent) :
    QObject(parent)
{
    ci = new clControlInterface(this);
    connect(ci, SIGNAL(hostDiscovered(QString, QString, QString)),
        this, SLOT(onHostDiscovered(QString, QString, QString)));
    connect(ci, SIGNAL(connected()),
        this, SLOT(onConnected()));
    connect(ci, SIGNAL(error(QString)),
        this, SLOT(onError(QString)));
    connect(ci, SIGNAL(response(QString, QString)),
        this, SLOT(onResponse(QString, QString)));
    connect(ci, SIGNAL(endOfResponse()),
        this, SLOT(onEndOfResponse()));
    connect(ci, SIGNAL(info(QString, QString, QString, QString, QString)),
        this, SLOT(onInfo(QString, QString, QString, QString, QString)));
    connect(ci, SIGNAL(license(bool, QString, QString)),
        this, SLOT(onLicense(bool, QString, QString)));
    connect(ci, SIGNAL(libraryHash(QString)),
        this, SLOT(onLibraryHash(QString)));
    connect(ci,
        SIGNAL(libraryDirectory(QString, QString,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString, QString, QString,
            QString, QString,
            QString, QString, bool,
            QVariantHash)),
        this,
        SLOT(onLibraryDirectory(QString, QString,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString, QString, QString,
            QString, QString,
            QString, QString, bool,
            QVariantHash)));
    connect(ci,
        SIGNAL(libraryFile(QString, QString,
            QString, QString, QString, QString,
            QString, QString,
            double, unsigned,
            QString, bool,
            QVariantHash)),
        this,
        SLOT(onLibraryFile(QString, QString,
            QString, QString, QString, QString,
            QString, QString,
            double, unsigned,
            QString, bool,
            QVariantHash)));
    connect(ci, SIGNAL(libraryPicture(QString, QByteArray)),
        this, SLOT(onLibraryPicture(QString, QByteArray)));
    connect(ci,
        SIGNAL(playlistItem(unsigned,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString,
            QString, QString, QString, QString, QString,
            double, QString, QByteArray)),
        this,
        SLOT(onPlaylistItem(unsigned,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString,
            QString, QString, QString, QString, QString,
            double, QString, QByteArray)));
    connect(ci, SIGNAL(playlistBegin(QString)),
        this, SLOT(onPlaylistBegin(QString)));
    connect(ci,
        SIGNAL(playlistEntry(
            QString, QString, QString, QString,
            double, qulonglong,
            bool, bool, unsigned, unsigned, unsigned, unsigned,
            double, double,
            QString, QString, QString, QString,
            QString, QString, QString, QString)),
        this,
        SLOT(onPlaylistEntry(
            QString, QString, QString, QString,
            double, qulonglong,
            bool, bool, unsigned, unsigned, unsigned, unsigned,
            double, double,
            QString, QString, QString, QString,
            QString, QString, QString, QString)));
    connect(ci, SIGNAL(playlists(QStringList)),
        this, SLOT(onPlaylists(QStringList)));
    connect(ci, SIGNAL(matrixProfileItem(QString)),
        this, SLOT(onMatrixProfileItem(QString)));
    connect(ci, SIGNAL(matrixProfile(QString)),
        this, SLOT(onMatrixProfile(QString)));
    connect(ci, SIGNAL(modesItem(unsigned, QString, int)),
        this, SLOT(onModesItem(unsigned, QString, int)));
    connect(ci, SIGNAL(filtersItem(unsigned, QString, int, unsigned, QString)),
        this, SLOT(onFiltersItem(unsigned, QString, int, unsigned, QString)));
    connect(ci, SIGNAL(shapersItem(unsigned, QString, int)),
        this, SLOT(onShapersItem(unsigned, QString, int)));
    connect(ci, SIGNAL(ratesItem(unsigned, unsigned)),
        this, SLOT(onRatesItem(unsigned, unsigned)));
    connect(ci, SIGNAL(junkFiltersItem(unsigned, QString, int)),
        this, SLOT(onJunkFiltersItem(unsigned, QString, int)));
    connect(ci, SIGNAL(volumeRangeResponse(double, double, bool, bool)),
        this, SLOT(onVolumeRangeResponse(double, double, bool, bool)));
    connect(ci, SIGNAL(displayResponse(int)),
        this, SLOT(onDisplayResponse(int)));
    connect(ci, SIGNAL(transportResponse(int, QString)),
        this, SLOT(onTransportResponse(int, QString)));
    connect(ci,
        SIGNAL(stateResponse(int,
            int, int, int, int, int, int,
            double,
            unsigned, unsigned,
            bool, bool, int, bool, bool, int,
            QString)),
        this,
        SLOT(onStateResponse(int,
            int, int, int, int, int, int,
            double,
            unsigned, unsigned,
            bool, bool, int, bool, bool, int,
            QString)));
    connect(ci,
        SIGNAL(statusResponse(int,
            unsigned, QString, int, int,
            double, unsigned,
            unsigned, unsigned, unsigned,
            bool,
            double, double,
            int, int,
            int, int,
            int, int,
            long,
            unsigned)),
        this,
        SLOT(onStatusResponse(int,
            unsigned, QString, int, int,
            double, unsigned,
            unsigned, unsigned, unsigned,
            bool,
            double, double,
            int, int,
            int, int,
            int, int,
            long,
            unsigned)));
    connect(ci,
        SIGNAL(statusIO(
            float, float,
            float)),
        this,
        SLOT(onStatusIO(
            float, float,
            float)));
    connect(ci, SIGNAL(inputsItem(QString)),
        this, SLOT(onInputsItem(QString)));

    statusSub = false;
}


clControlApplication::~clControlApplication ()
{
}


void clControlApplication::start (const QString &host, const QStringList &argsp)
{
    if (host == "--discover")
    {
        QTimer::singleShot(1000,
            QCoreApplication::instance(),
            SLOT(quit()));
        ci->discoverHosts();
    }
    else
    {
        args = argsp;
        ci->connectToHost(host, 4321);
    }
}


void clControlApplication::onHostDiscovered (QString address,
    QString friendlyName, QString software)
{
    qDebug("[%s] '%s' - %s",
        address.toUtf8().constData(),
        friendlyName.toUtf8().constData(),
        software.toUtf8().constData());
}


void clControlApplication::onConnected ()
{
    bool queued = false;

    if (args.isEmpty())
    {
        qDebug("empty argument list");
        QCoreApplication::quit();
        return;
    }

    if (args.first().startsWith(QStringLiteral("--")))
    {
        QString cmd(args.takeFirst());
        QString arg1;

        if (!args.isEmpty())
            arg1 = args.takeFirst();

        if (cmd == "--get-info")
            ci->getInfo();
        else if (cmd == "--get-license")
            ci->getLicense();
        else if (cmd == "--reset")
            ci->reset();
        else if (cmd == "--configuration-load")
            ci->configurationLoad(arg1);
        else if (cmd == "--library-load")
            ci->libraryLoad(arg1);
        else if (cmd == "--library-hash")
            ci->libraryGetHash();
        else if (cmd == "--library-get")
            ci->libraryGet(false);
        else if (cmd == "--library-picture")
            ci->libraryPictureByPath(arg1);
        else if (cmd == "--playlist-remove")
            ci->playlistRemove(arg1.toInt());
        else if (cmd == "--playlist-move-up")
            ci->playlistMoveUp(arg1.toInt());
        else if (cmd == "--playlist-move-down")
            ci->playlistMoveDown(arg1.toInt());
        else if (cmd == "--playlist-get")
            ci->playlistGet(false);
        else if (cmd == "--playlist-get-single")
            ci->playlistGetSingle(arg1);
        else if (cmd == "--playlist-get-all")
            ci->playlistGetAll();
        else if (cmd == "--playlist-list")
            ci->playlistGetList();
        else if (cmd == "--playlist-load")
            ci->playlistLoad(arg1);
        else if (cmd == "--playlist-save")
            ci->playlistSave(arg1);
        else if (cmd == "--playlist-delete")
            ci->playlistDelete(arg1);
        else if (cmd == "--playlist-upload")
        {
            QFileInfo playlistInfo(arg1);
            QFile playlistFile(arg1);
            playlistFile.open(QIODevice::ReadOnly);
            ci->playlistUpload(
                playlistInfo.fileName(),
                playlistFile.readAll());
        }
        else if (cmd == "--playlist-clear")
            ci->playlistClear();
        else if (cmd == "--matrix-list")
            ci->matrixListProfiles();
        else if (cmd == "--get-matrix")
            ci->matrixGetProfile();
        else if (cmd == "--set-matrix")
            ci->matrixSetProfile(arg1);
        else if (cmd == "--select-track")
            ci->selectTrack(arg1.toInt());
        else if (cmd == "--load-removable")
            ci->loadRemovable();
        else if (cmd == "--play")
            ci->play();
        else if (cmd == "--play-next-uri")
            ci->playNextURI(arg1);
        else if (cmd == "--pause")
            ci->pause();
        else if (cmd == "--stop")
            ci->stop();
        else if (cmd == "--previous")
            ci->previous();
        else if (cmd == "--next")
            ci->next();
        else if (cmd == "--backward")
            ci->backward();
        else if (cmd == "--forward")
            ci->forward();
        else if (cmd == "--seek")
            ci->seek(arg1.toInt());
        else if (cmd == "--volume-down")
            ci->volumeDown();
        else if (cmd == "--volume-up")
            ci->volumeUp();
        else if (cmd == "--mute")
            ci->volumeMute();
        else if (cmd == "--volume")
            ci->volume(arg1.toDouble());
        else if (cmd == "--state")
            ci->state();
        else if (cmd == "--status")
        {
            statusSub = true;
            ci->status(statusSub);
        }
        else if (cmd == "--get-status")
        {
            statusSub = false;
            ci->status(statusSub);
        }
        else if (cmd == "--set-mode")
            ci->setMode(arg1.toInt());
        else if (cmd == "--get-modes")
            ci->getModes();
        else if (cmd == "--set-filter")
        {
            if (!args.isEmpty())
            {
                QString arg2(args.takeFirst());
                ci->setFilter(arg1.toInt(), arg2.toInt());
            }
            else
                ci->setFilter(arg1.toInt());
        }
        else if (cmd == "--get-filters")
            ci->getFilters();
        else if (cmd == "--set-shaping")
            ci->setShaping(arg1.toInt());
        else if (cmd == "--get-shapers")
            ci->getShapers();
        else if (cmd == "--set-rate")
            ci->setRate(arg1.toInt());
        else if (cmd == "--get-rates")
            ci->getRates();
        else if (cmd == "--get-junk-filters")
            ci->getJunkFilters();
        else if (cmd == "--volume-range")
            ci->volumeRange();
        else if (cmd == "--set-invert")
            ci->setInvert(arg1.toInt());
        else if (cmd == "--set-adaptive")
            ci->setAdaptive(arg1.toInt());
        else if (cmd == "--set-convolution")
            ci->setConvolution(arg1.toInt());
        else if (cmd == "--set-junkfilter")
            ci->setJunkFilter(arg1.toInt());
        else if (cmd == "--set-repeat")
            ci->setRepeat(arg1.toInt());
        else if (cmd == "--set-random")
            ci->setRandom(arg1.toInt());
        else if (cmd == "--set-display")
            ci->setDisplay(arg1.toInt());
        else if (cmd == "--get-display")
            ci->getDisplay();
        else if (cmd == "--get-transport")
            ci->getTransport();
        else if (cmd == "--set-transport")
        {
            QString arg2(QStringLiteral(""));
            if (!args.isEmpty())
                arg2 = args.takeFirst();
            ci->setTransport(arg1.toInt(), arg2);
        }
        else if (cmd == "--set-transport-path")
            ci->setTransportPath(arg1);
        else if (cmd == "--set-transport-rate")
            ci->setTransportRate(arg1.toUInt());
        else if (cmd == "--get-inputs")
            ci->getInputs();
        else
            QCoreApplication::quit();
    }
    else
    {
        foreach (QString arg, args)
        {
            if (arg == "-q")
            {
                queued = true;
            }
            else if (arg.startsWith("file:") ||
                arg.startsWith("http:") || arg.startsWith("https:") ||
                arg.startsWith("audio:"))
            {
                ci->playlistAdd(arg, queued);
            }
            else
            {
                QDir fullPath(arg);
                ci->playlistAdd(
                    QDir::toNativeSeparators(fullPath.canonicalPath()),
                    queued);
            }
        }
    }
}


void clControlApplication::onError (QString error)
{
    qDebug("error: %s", error.toUtf8().constData());

    QCoreApplication::exit(1);
}


void clControlApplication::onResponse (QString cmd, QString resp)
{
    if (!resp.isEmpty())
        qDebug("%s: %s", cmd.toUtf8().constData(), resp.toUtf8().constData());

    QCoreApplication::quit();
}


void clControlApplication::onEndOfResponse ()
{
    if (!statusSub)
        QCoreApplication::quit();
}


void clControlApplication::onInfo (QString name,
    QString product, QString version,
    QString platform, QString engine)
{
    qDebug("'%s' %s/%s/%s/%s",
        name.toUtf8().constData(),
        product.toUtf8().constData(),
        version.toUtf8().constData(),
        platform.toUtf8().constData(),
        engine.toUtf8().constData());
}


void clControlApplication::onLicense (bool valid, QString name,
    QString fingerprint)
{
    qDebug("%d:%s:%s",
        valid,
        name.toUtf8().constData(),
        fingerprint.toUtf8().constData());
    if (valid)
        QCoreApplication::exit(0);
    else
        QCoreApplication::exit(1);
}


void clControlApplication::onLibraryHash (QString hash)
{
    qDebug("hash: %s", hash.toUtf8().constData());
}


void clControlApplication::onLibraryDirectory (QString path, QString hash,
    unsigned rate, unsigned bits, unsigned chan, unsigned bitrate,
    QString artist, QString composer, QString performer, QString album,
    QString genre, QString date,
    QString cover, QString booklet, bool favorite,
    QVariantHash hashAnalysis)
{
    Q_UNUSED(booklet);
    Q_UNUSED(hashAnalysis);

    qDebug("directory %s [%s]:\n\t%s/%s/%s/%s/%s/%s (%u/%u/%u/%u) \"%s\" %c",
        path.toUtf8().constData(),
        hash.toUtf8().constData(),
        artist.toUtf8().constData(),
        composer.toUtf8().constData(),
        performer.toUtf8().constData(),
        album.toUtf8().constData(),
        genre.toUtf8().constData(),
        date.toUtf8().constData(),
        rate, bits, chan, bitrate,
        cover.toUtf8().constData(),
        favorite ? '*' : ' ');
}


void clControlApplication::onLibraryFile (QString name, QString hash,
    QString song, QString artist, QString composer, QString performer,
    QString genre, QString date,
    double length, unsigned trackno,
    QString cover, bool favorite,
    QVariantHash hashAnalysis)
{
    Q_UNUSED(hashAnalysis);

    qDebug("\tfile \"%s\" [%s] (%u):\n\t\t%s/%s/%s/%s/%s/%s (%f) \"%s\" %c",
        name.toUtf8().constData(),
        hash.toUtf8().constData(),
        trackno,
        song.toUtf8().constData(),
        artist.toUtf8().constData(),
        composer.toUtf8().constData(),
        performer.toUtf8().constData(),
        genre.toUtf8().constData(),
        date.toUtf8().constData(),
        length,
        cover.toUtf8().constData(),
        favorite ? '*' : ' ');
}


void clControlApplication::onLibraryPicture (QString type,
    QByteArray picture)
{
    static const char *idPNG = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a";
    /*static const char *idJPG = "\xff\xd8";*/

    if (picture.size() == 0)
    {
        qDebug("no picture");
        return;
    }

    QCryptographicHash hash(QCryptographicHash::Md5);
    hash.addData(picture);
    qDebug("picture: %s [%s]",
        type.toUtf8().constData(),
        hash.result().toHex().constData());

    QByteArray baIdPNG(idPNG, 8);
    QFile picfile(picture.startsWith(baIdPNG) ?
        QStringLiteral("library.png") : QStringLiteral("library.jpg"));
    picfile.open(QIODevice::WriteOnly|QIODevice::Truncate);
    picfile.write(picture);
}


void clControlApplication::onPlaylistItem (unsigned index,
    unsigned rate, unsigned bits, unsigned channels, unsigned bitrate,
    QString uri, QString mime,
    QString artist, QString composer, QString performer,
    QString album, QString song,
    double length, QString coverUrl, QByteArray picture)
{
    qDebug("[%u] (%u/%u/%u/%u) %s {%s}\n\t%s/%s/%s/%s/%s %.3f (%lld) \"%s\"",
        index,
        rate, bits, channels, bitrate,
        uri.toUtf8().constData(), mime.toUtf8().constData(),
        artist.toUtf8().constData(),
        composer.toUtf8().constData(),
        performer.toUtf8().constData(),
        album.toUtf8().constData(), song.toUtf8().constData(),
        length, picture.size(), coverUrl.toUtf8().constData());
}


void clControlApplication::onPlaylistBegin (QString name)
{
    qDebug("%s:", name.toUtf8().constData());
}


void clControlApplication::onPlaylistEntry (
    QString type, QString uri, QString mime, QString cover,
    double length, qulonglong frames,
    bool fp, bool sdm, unsigned rate, unsigned bits, unsigned chs, unsigned br,
    double trackGain, double albumGain,
    QString artist, QString composer, QString performer, QString albumArtist,
    QString album, QString song, QString genre, QString date)
{
    qDebug("\t[%s] \"%s\" %s %s %f %llu %d %d %u/%u/%u/%u %f/%f %s/%s/%s/%s %s/%s %s %s",
        type.toUtf8().constData(),
        uri.toUtf8().constData(),
        mime.toUtf8().constData(),
        cover.toUtf8().constData(),
        length, frames,
        (int) fp, (int) sdm, rate, bits, chs, br,
        trackGain, albumGain,
        artist.toUtf8().constData(),
        composer.toUtf8().constData(),
        performer.toUtf8().constData(),
        albumArtist.toUtf8().constData(),
        album.toUtf8().constData(),
        song.toUtf8().constData(),
        genre.toUtf8().constData(),
        date.toUtf8().constData());
}


void clControlApplication::onPlaylists (QStringList playlistList)
{
    foreach (const QString &name, playlistList)
        qDebug("%s", name.toUtf8().constData());
}


void clControlApplication::onMatrixProfileItem (QString profile)
{
    qDebug("%s", profile.toUtf8().constData());
}


void clControlApplication::onMatrixProfile (QString profile)
{
    qDebug("%s", profile.toUtf8().constData());
}


void clControlApplication::onModesItem (unsigned index,
    QString name, int value)
{
    qDebug("[%u] \"%s\" %d", index, name.toUtf8().constData(), value);
}


void clControlApplication::onFiltersItem (unsigned index,
    QString name, int value, unsigned arg, QString description)
{
    qDebug("[%u] \"%s\" %d %u \"%s\"",
        index, name.toUtf8().constData(), value, arg,
        description.toUtf8().constData());
}


void clControlApplication::onShapersItem (unsigned index,
    QString name, int value)
{
    qDebug("[%u] \"%s\" %d", index, name.toUtf8().constData(), value);
}


void clControlApplication::onRatesItem (unsigned index, unsigned rate)
{
    qDebug("[%u] %u", index, rate);
}


void clControlApplication::onJunkFiltersItem (unsigned index,
    QString name, int value)
{
    qDebug("[%u] \"%s\" %d", index, name.toUtf8().constData(), value);
}


void clControlApplication::onVolumeRangeResponse (double minVol, double maxVol,
    bool enabled, bool adaptive)
{
    qDebug("volume range: %f %f (%d) ~%d", minVol, maxVol,
        (int) enabled, (int) adaptive);
}


void clControlApplication::onDisplayResponse (int value)
{
    qDebug("display: %d", value);
}


void clControlApplication::onTransportResponse (int value, QString arg)
{
    qDebug("transport: %d \"%s\"", value, arg.toUtf8().constData());
}


void clControlApplication::onStateResponse (int state,
    int mode, int filter, int filter1x, int filterNx, int shaper, int rate,
    double volume,
    unsigned active_mode, unsigned active_rate,
    bool invert, bool convolution, int repeat, bool random,
    bool adaptive, int filterJunk, QString matrixProfile)
{
    qDebug("state: %d %d:(%d, %d (%d, %d), %d) %f %u:%u %u %u %d %u %u %u '%s'",
        state, mode, filter, filter1x, filterNx, shaper, rate, volume,
        active_mode, active_rate,
        (unsigned) invert, (unsigned) convolution, repeat, (unsigned) random,
        (unsigned) adaptive, (unsigned) filterJunk,
        matrixProfile.toUtf8().constData());
}


void clControlApplication::onStatusResponse (int state,
    unsigned track, QString trackId, int min, int sec,
    double volume, unsigned clips,
    unsigned numTracks, unsigned trackSerial, unsigned transportSerial,
    bool queued,
    double position, double length,
    int beginMin, int beginSec,
    int remainMin, int remainSec,
    int totalMin, int totalSec,
    long outputDelay,
    unsigned apod)
{
    Q_UNUSED(trackId);
    Q_UNUSED(trackSerial);
    Q_UNUSED(transportSerial);

    qDebug("status: %d %u/%u %d:%d %f %u/%u %f/%f %d:%d/%d:%d/%d:%d {%c} (%ld)",
        state,
        track, numTracks, min, sec,
        volume, clips, apod,
        position, length,
        beginMin, beginSec,
        remainMin, remainSec,
        totalMin, totalSec,
        queued ? 'q' : 'n',
        outputDelay);

    if (!statusSub)
        QCoreApplication::quit();

    if (state == 0)
        QCoreApplication::quit();
}


void clControlApplication::onStatusIO (
    float inputFill, float outputFill,
    float processSpeed)
{
    qDebug("statusIO: %f %f %f", inputFill, outputFill, processSpeed);
}


void clControlApplication::onInputsItem (QString name)
{
    qDebug("input: %s", name.toUtf8().constData());
}

