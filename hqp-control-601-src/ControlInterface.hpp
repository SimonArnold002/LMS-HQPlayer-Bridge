// $Id: ControlInterface.hpp 13554 2026-03-02 20:33:29Z jussi $

/*

  HQPlayer Qt-based control interface.
  Copyright (C) 2011-2026 Jussi Laako.

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


#ifndef CONTROLINTERFACE_HPP
#define CONTROLINTERFACE_HPP

#include <atomic>
#include <memory>

#include <QByteArray>
#include <QHash>
#include <QMutex>
#include <QObject>
#include <QPair>
#include <QQueue>
#include <QStack>
#include <QString>
#include <QStringList>
#include <QTcpSocket>
#include <QThread>
#include <QUdpSocket>
#include <QVariant>
#include <QVersionNumber>
#include <QWaitCondition>
#include <QXmlStreamReader>
#include <QXmlStreamWriter>


#define CONTROLINTERFACE_FILTER_APODIZING               0x00000001


class clControlInterfacePrivate;


class clMeterInterface : public QObject
{
        Q_OBJECT

        std::atomic<bool> connected;

        QString serverHost;
        quint16 serverPort;
        QTcpSocket *msocket;
        QByteArray readBuffer;
        QQueue< QPair<QByteArray, QByteArray> > dataQueue;
        QMutex mutex;
        QWaitCondition condition;

    public:
#       pragma pack(1)
        typedef struct _head_t
        {
            unsigned version;
            unsigned channels;
            unsigned xformLength;
            int xformBits;  // negative means floating point
            float bandwidth;
            float xformTime;
            float xformGain;
            float reserved2;
        } head_t;
        typedef struct _data_t
        {
            float peakMax;
            float peak;
            float rms;
            float rmsMax;
        } data_t;
#       pragma pack()

        clMeterInterface (QObject * = nullptr);
        virtual ~clMeterInterface ();
        void setServer (QString, quint16);
        bool getMetering ()
            { return connected.load(); }
        bool getData (QByteArray &, QByteArray &);
        bool waitData (QByteArray &, QByteArray &, unsigned);

    public slots:
        void onSetMetering (bool);

    protected slots:
        void onConnected ();
        void onDisconnected ();
        void onError (QAbstractSocket::SocketError);
        void onReadyRead ();

    signals:
        // message
        void error (QString);
        // header, data
        void meterUpdated ();

    protected:
        virtual bool isConnected ();
};


class clControlInterface : public QObject
{
        Q_OBJECT

        std::unique_ptr<clControlInterfacePrivate> p;

        QString serverHost;
        quint16 serverPort;
        QUdpSocket *discoSocket;
        QTcpSocket *csocket;
        QXmlStreamReader *xreader;
        QXmlStreamWriter *xwriter;
        QByteArray recvBuffer;
        bool hasSessionKey;
        QStack<QString> parentStack;
        QString lastResult;
        QString activeCfg;
        bool isAlbum;
        int pictureSize;
        QString pictureMime;
        QByteArray pictureData;
        QStringList playlistList;

        void completeAuthentication ();

    public:
        enum State
        {
            STATE_STOPPED = 0,
            STATE_PAUSED,
            STATE_PLAYING,
            STATE_STOPREQ,
        };
        enum Repeat
        {
            REPEAT_NONE = 0,
            REPEAT_SINGLE,
            REPEAT_ALL
        };
        enum Display
        {
            DISPLAY_TIME = 0,
            DISPLAY_REMAIN,
            DISPLAY_TOTAL_REMAIN,
        };
        enum Transport
        {
            TRANSPORT_NONE = 0,
            TRANSPORT_CD,
            TRANSPORT_FLAC,
            TRANSPORT_DSD,
            TRANSPORT_IFF,
            TRANSPORT_AUDIO,
            TRANSPORT_WV,
            TRANSPORT_MP3,
            TRANSPORT_RAW = 0xe0,
            TRANSPORT_FFMPEG = 0xe1,
            TRANSPORT_PLAYLIST = 0xf0,
            TRANSPORT_NOISE = 0xff
        };

        QThread *meterThread;
        clMeterInterface *meterInterface;

        clControlInterface (QObject * = nullptr);
        virtual ~clControlInterface ();

        void discoverHosts (quint16 = 4321);

        void connectToHost (const QString &, quint16 = 4321);
        void disconnectFromHost ();
        bool isConnected ();
        void sendKeepAlive ();
        void authenticate (const QString &,
            const char *, const char *);
        bool isAuthenticated ();
        void getInfo ();
        void getLicense ();
        void reset ();
        void configurationList ();
        void configurationGet ();
        void configurationLoad (const QString &);
        void libraryLoad (const QString &);  // not implemented on v4/v5
        void libraryGetHash ();
        void libraryGet (bool = false);
        void libraryPictureByPath (const QString &);
        void libraryPictureByHash (const QString &);
        void libraryFavoriteGetByPath (const QString &,
                const QString & = QString());
        void libraryFavoriteGetByHash (const QString &,
                const QString & = QString());
        void libraryFavoriteSetByPath (bool, const QString &,
                const QString & = QString());
        void libraryFavoriteSetByHash (bool, const QString &,
                const QString & = QString());
        void libraryFavoriteSetCurrent (bool);
        void playlistAdd (const QString &, bool = false, bool = false,
            const QVariantHash & = QVariantHash(),
            bool = false, bool = false);
        void playlistRemove (int);
        void playlistMoveUp (int);
        void playlistMoveDown (int);
        void playlistGet (bool = false);
        void playlistGetSingle (const QString &);
        void playlistGetAll ();
        void playlistGetList ();
        void playlistLoad (const QString &);
        void playlistSave (const QString &);
        void playlistDelete (const QString &);
        void playlistUpload (const QString &, const QByteArray &);
        void playlistClear ();
        void matrixListProfiles ();
        void matrixGetProfile ();
        void matrixSetProfile (const QString &);
        // both selectTrack() and play() will emit playComplete() signal
        void selectTrack (int);
        void loadRemovable ();
        void play (bool = false);
        void playNextURI (const QString &,
            const QVariantHash & = QVariantHash(),
            bool = false);
        void pause ();
        void stop ();
        void previous ();
        void next ();
        void backward ();
        void forward ();
        void seek (int);
        void volumeDown ();
        void volumeUp ();
        void volumeMute ();
        void volume (double);
        void volumeRange ();
        void state ();
        void status (bool);
        void setMode (int);
        void getModes ();
        void setFilter (int, int = -1);
        void getFilters ();
        void setShaping (int);
        void getShapers ();
        void setRate (int);
        void getRates ();
        void setJunkFilter (int);
        void getJunkFilters ();
        void setInvert (bool);
        void setAdaptive (bool);
        void setConvolution (bool);
        void setRepeat (int);
        void setRandom (bool);
        void setDisplay (int);
        void getDisplay ();
        void getTransport ();
        void setTransport (int, const QString &, bool = false);
        void setTransportPath (const QString &, bool = false);
        void setTransportRate (unsigned);
        void getInputs ();
        // - metering
        void setMetering (bool);
        bool getMetering ();

    protected slots:
        void onDiscoReadyRead ();
        void onConnected ();
        void onDisconnected ();
        void onError (QAbstractSocket::SocketError);
        void onReadyRead ();

    signals:
        void hostDiscovered (QString, QString, QString);

        void connected ();
        void disconnected ();
        void authenticated (QVersionNumber);
        void error (QString);
        void response (QString, QString);
        void endOfResponse ();
        // end of binary data, such as picture
        void endOfData ();
        // name, product, version, platform, engine
        void info (QString, QString, QString, QString, QString);
        // valid, name, fingerprint
        void license (bool, QString, QString);
        // name
        void configurationItem (QString);
        // active config
        void configurationEnd (QString);
        void configurationActive (QString);
        // library hash
        void libraryHash (QString);
        // path, hash
        // rate, bits, channels, bitrate
        // artist, composer, performer, album,
        // genre, date
        // coverurl, bookleturl, favorite
        // analysis data
        void libraryDirectory (QString, QString,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString, QString, QString,
            QString, QString,
            QString, QString, bool,
            QVariantHash);
        // type, picture
        void libraryPicture (QString, QByteArray);
        // name, hash
        // song, artist, composer, performer
        // genre, date
        // length, trackno
        // coverurl, favorite
        // analysis data
        void libraryFile (QString, QString,
            QString, QString, QString, QString,
            QString, QString,
            double, unsigned,
            QString, bool,
            QVariantHash);
        // end of library directory
        void libraryDirectoryEnd ();
        // end of library items
        void libraryEnd ();
        // favorite response
        void favorite (QString, QString, QString, bool);
        // index
        // rate, bits, channels, bitrate
        // uri, mime
        // artist, composer, performer, album, song
        // length, cover url, picture
        void playlistItem (unsigned,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString,
            QString, QString, QString, QString, QString,
            double, QString, QByteArray);
        // end of playlist items
        // album
        void playlistEnd (bool);
        // playlist begin
        // name
        void playlistBegin (QString);
        // playlist entry
        // type, uri, mime, cover,
        // length, frames,
        // float, sdm, rate, bits, channels, bitrate
        // track gain, album gain
        // artist, composer, performer, album artist
        // album, song, genre, date
        void playlistEntry (
            QString, QString, QString, QString,
            double, qulonglong,
            bool, bool, unsigned, unsigned, unsigned, unsigned,
            double, double,
            QString, QString, QString, QString,
            QString, QString, QString, QString);
        // end of playlist
        void playlistEnd ();
        // list of playlists
        void playlists (QStringList);
        // name
        void matrixProfileItem (QString);
        void matrixProfileEnd ();
        // name
        void matrixProfile (QString);
        // play request completed
        void playComplete ();
        // stop request completed
        void stopComplete ();
        // index, name, value, description
        void modesItem (unsigned, QString, int);
        void modesEnd ();
        void filtersItem (unsigned, QString, int, unsigned, QString);
        void filtersEnd ();
        void shapersItem (unsigned, QString, int);
        void shapersEnd ();
        // index, rate
        void ratesItem (unsigned, unsigned);
        void ratesEnd ();
        // index, name, value
        void junkFiltersItem (unsigned, QString, int);
        void junkFiltersEnd ();
        // min, max, enabled, adaptive
        void volumeRangeResponse (double, double, bool, bool);
        // display
        void displayResponse (int);
        // type, arg
        void transportResponse (int, QString);
        // state
        // mode, filter, shaper, rate,
        // volume,
        // active_mode, active_rate,
        // invert, convolution, repeat, random, adaptive, junk_filter
        // matrix_profile
        void stateResponse (int,
            int, int, int, int, int, int,
            double,
            unsigned, unsigned,
            bool, bool, int, bool, bool, int,
            QString);
        // state
        // track, track_id, min, sec
        // volume, limits,
        // numtracks, trackSerial, transportSerial
        // queued,
        // position, length
        // begin_min, begin_sec,
        // remain_min, remain_sec
        // total_min, total_sec,
        // output_delay_us
        // apodization
        void statusResponse (int,
            unsigned, QString, int, int,
            double, unsigned,
            unsigned, unsigned, unsigned,
            bool,
            double, double,
            int, int,
            int, int,
            int, int,
            long,
            unsigned);
        // mode, filter, shaper
        // rate, bits, channels
        // junk_filter, correction,
        // random, repeat
        void statusInfo (
            QString, QString, QString,
            unsigned, unsigned, unsigned,
            int, bool,
            bool, int);
        // input_fill, output_fill,
        // process_speed
        void statusIO (
            float, float,
            float);
        void statusMetadata (QVariantHash);
        // name
        void inputsItem (QString);
        void inputsEnd ();

        // internal
        void enableMetering (bool);

    private:
        QString fromEscaped (const QString &);
};

#endif  // CONTROLINTERFACE_HPP

